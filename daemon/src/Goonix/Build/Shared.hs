{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | HS-12 shared scheduler (DECISIONS.md point 2, 00-plan.md §7).
--
-- One job limit and one goal per derivation across the clients of one daemon.
-- The pure per-request scheduler (Goonix.Build.Scheduler) still chooses starts
-- and blocked failures within a request; this module adds the process-wide
-- sharing the C++ daemon has through its single-threaded goal loop:
--
--   * one job limit: a shared running-job count, so the daemon-wide
--     @build-max-jobs@ is enforced across all clients, not per connection;
--   * one goal per derivation: when a client asks for a derivation another
--     client is already building, it attaches to that goal as a waiter instead
--     of starting a second build; all waiters are notified when the goal ends.
--
-- The lock files stay, for helpers and for other daemons: this sharing is
-- in-process only.  Two daemon processes on one store still serialize through
-- the output locks and the GC lock, exactly as before.
module Goonix.Build.Shared
  ( Shared
  , newShared
  , sharedSlots
  , raiseLimit
  , GoalResult (..)
  , withGoal
  , acquireSlot
  , releaseSlot
  , runningJobs
  ) where

import Control.Concurrent (forkIO, killThread, ThreadId)
import Control.Concurrent.STM
  ( TVar, TMVar, atomically, newTVarIO, newEmptyTMVarIO, newTVar, newEmptyTMVar
  , readTVar, writeTVar, modifyTVar', retry, putTMVar, readTMVar )
import Control.Exception (SomeException, throwIO, try, onException)
import Control.Monad (forM_, when)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map

-- | The process-wide shared scheduler state of one daemon.
data Shared = Shared
  { sharedRunning :: !(TVar Int)
  -- ^ Number of jobs running across all clients (the shared job limit).
  , sharedLimit :: !(TVar Int)
  -- ^ The daemon-wide build-max-jobs.  One limit across all clients; a client
  -- that asks for more jobs raises it (as the C++ daemon's settings do), so it
  -- is never tighter than a client's request.
  , sharedGoals :: !(TVar (Map.Map ByteString Goal))
  -- ^ One goal per derivation, with the clients waiting on it.
  }

data Goal = Goal
  { goalWaiters :: !(TVar [TMVar GoalResult])
  -- ^ Clients attached to this goal, notified when it ends.
  , goalDone :: !(TVar (Maybe GoalResult))
  -- ^ The result once the goal has ended (Nothing while running).
  , goalStarted :: !(TVar Bool)
  -- ^ Whether the daemon-owned worker has been forked (startGoal is idempotent).
  , goalWorker :: !(TVar (Maybe ThreadId))
  -- ^ The daemon-owned worker, killed when the last interested client leaves.
  }

-- | How a goal ended: success, or the exception that failed it.
data GoalResult = GoalSucceeded | GoalFailed SomeException

newShared :: Int -> IO Shared
newShared limit = Shared <$> newTVarIO 0 <*> newTVarIO (max 0 limit) <*> newTVarIO Map.empty

sharedSlots :: Shared -> IO Int
sharedSlots shared = atomically (readTVar (sharedLimit shared))

-- | Raise the shared job limit to at least the given value.  A client asking
-- for more build jobs raises the daemon-wide limit (the C++ daemon reads the
-- connection's build-max-jobs setting); the limit is never lowered here, so a
-- running request is not starved below what it asked for.
raiseLimit :: Shared -> Int -> IO ()
raiseLimit shared requested = atomically $
  modifyTVar' (sharedLimit shared) (\current -> max current (max 0 requested))

runningJobs :: Shared -> IO Int
runningJobs shared = atomically (readTVar (sharedRunning shared))

-- | Acquire one shared job slot, blocking while the daemon-wide limit is reached.
acquireSlot :: Shared -> IO ()
acquireSlot shared = atomically $ do
  running <- readTVar (sharedRunning shared)
  limit <- readTVar (sharedLimit shared)
  if running < limit
    then writeTVar (sharedRunning shared) (running + 1)
    else retry

releaseSlot :: Shared -> IO ()
releaseSlot shared = atomically $
  modifyTVar' (sharedRunning shared) (\n -> max 0 (n - 1))

-- | Run an action as the single goal for a derivation, or attach to the goal
-- another client is already running.  The first client for a derivation starts
-- the build in a DAEMON-OWNED worker thread; every client (including the first)
-- then waits on that goal.  Because the build runs in its own thread, a client
-- disconnect cancels only that client's wait — the goal keeps running while any
-- other client is still interested, exactly as the C++ daemon's goal outlives
-- any one client.  When the LAST interested client leaves, the worker is killed
-- (so a single client's disconnect still kills its build, as the disconnect
-- test requires).  A client that arrives after the goal ended re-runs @build@
-- (the output is then valid, so it is a no-op recheck).  This is the in-process
-- "one goal per derivation"; the output locks still exclude other processes.
--
-- Only SUCCESS is shared.  The starter gets the goal's failure (it ran the
-- build with its own settings); a waiter whose goal failed runs its own attempt
-- with its own settings, as a waiter on the output lock would in C++.  The
-- caller shares goals only between Normal-mode requests — Check and Repair run
-- their own build (see the engine).
--
-- @build@ must own its temporary roots and store handle and tolerate a gone
-- client: the daemon-owned worker may outlive the client that started it.
withGoal :: Shared -> ByteString -> IO () -> IO ()
withGoal shared derivation build = do
  (waiter, start) <- atomically $ do
    goals <- readTVar (sharedGoals shared)
    case Map.lookup derivation goals of
      Just goal -> do
        done <- readTVar (goalDone goal)
        case done of
          -- The goal already ended: re-run the build (a valid-output recheck).
          Just _ -> pure (Nothing, False)
          Nothing -> do
            w <- attach goal
            started <- readTVar (goalStarted goal)
            pure (Just w, not started)
      Nothing -> do
        goal <- Goal <$> newTVar [] <*> newTVar Nothing <*> newTVar False <*> newTVar Nothing
        writeTVar (sharedGoals shared) (Map.insert derivation goal goals)
        w <- attach goal
        pure (Just w, True)
  case waiter of
    Nothing -> build
    Just w -> do
      when start (startGoal shared derivation build)
      -- Wait for the goal; if this client is cancelled (disconnect), detach.
      -- When the last interested client detaches, kill the daemon-owned worker.
      r <- atomically (readTMVar w) `onException` detach w
      finish start r
  where
    attach goal = do
      waiter <- newEmptyTMVar
      modifyTVar' (goalWaiters goal) (waiter :)
      pure waiter
    detach w = do
      toKill <- atomically $ do
        goals <- readTVar (sharedGoals shared)
        case Map.lookup derivation goals of
          Nothing -> pure Nothing
          Just goal -> do
            waiters <- readTVar (goalWaiters goal)
            let remaining = filter (/= w) waiters
            writeTVar (goalWaiters goal) remaining
            -- When no client is still interested, kill the worker and drop the
            -- goal: a single client's disconnect still kills its build.
            if null remaining
              then do
                worker <- readTVar (goalWorker goal)
                writeTVar (sharedGoals shared) (Map.delete derivation goals)
                pure worker
              else pure Nothing
      forM_ toKill killThread
    -- Share only SUCCESS.  The starter ran the build with its own settings, so
    -- it gets the goal's failure.  A WAITER whose goal failed runs its own
    -- attempt with its own settings, exactly as a waiter on the output lock
    -- would in C++: the goal may have failed because of the starter's settings
    -- (silent-time, timeout, substituters) or a transient fault, which need not
    -- apply to this client.  The failure cache, when enabled, stays the only
    -- shared failure.
    finish _ GoalSucceeded = pure ()
    finish True (GoalFailed exception) = throwIO exception
    finish False (GoalFailed _exception) = build

-- | Fork the daemon-owned worker for a goal, once.  The worker runs the build,
-- records the result, notifies every waiter and removes the goal.  It is not
-- tied to any client's thread, so a client disconnect does not kill it while
-- other clients are still interested.
startGoal :: Shared -> ByteString -> IO () -> IO ()
startGoal shared derivation build = do
  fork <- atomically $ do
    goals <- readTVar (sharedGoals shared)
    case Map.lookup derivation goals of
      Just goal -> do
        started <- readTVar (goalStarted goal)
        if started then pure False else do
          writeTVar (goalStarted goal) True
          pure True
      Nothing -> pure False
  when fork $ do
    worker <- forkIO $ do
      outcome <- try build
      let result = either GoalFailed (const GoalSucceeded) outcome
      atomically $ do
        goals <- readTVar (sharedGoals shared)
        case Map.lookup derivation goals of
          Just goal -> do
            writeTVar (goalDone goal) (Just result)
            waiters <- readTVar (goalWaiters goal)
            mapM_ (\w -> putTMVar w result) waiters
          Nothing -> pure ()
      atomically $ modifyTVar' (sharedGoals shared) (Map.delete derivation)
    atomically $ do
      goals <- readTVar (sharedGoals shared)
      case Map.lookup derivation goals of
        Just goal -> writeTVar (goalWorker goal) (Just worker)
        Nothing -> pure ()