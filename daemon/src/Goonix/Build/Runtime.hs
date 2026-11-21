{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | One client request interpreted by the pure scheduler. Jobs discover
-- dependencies lazily; the model controls slots, starts and blocked failures.
module Goonix.Build.Runtime
  ( JobSpec (..)
  , Outcome (..)
  , runScheduled
  , runScheduledWithCancel
  , runScheduledShared
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar, readMVar)
import Control.Concurrent.STM (TQueue, TVar, atomically, newTQueueIO, newTVarIO, readTQueue, readTVar, retry, tryReadTQueue, writeTQueue, writeTVar)
import Control.Exception (SomeException, fromException, mask, onException, throwIO, try, toException, finally, uninterruptibleMask_)
import Control.Monad (foldM, forM, forM_, unless, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Goonix.Build.Scheduler (Action (..), Event (..), Job (..), JobKind (..), Status (..), State, addJob, addDependencyJobsWithKinds, initialState, jobs, step)
import Goonix.Build.Shared (Shared, acquireSlot, releaseSlot)
import Goonix.Store.ReadOnly (StoreError (..), storeError)

data JobSpec = JobSpec
  { jobId :: !ByteString
  , jobWanted :: !(Set.Set ByteString)
  , jobKind :: !JobKind
  , jobRun :: !(Set.Set ByteString -> IO (Outcome [Dependency]))
  }

data Outcome a = Done | Need a deriving (Eq, Show)
type Dependency = (ByteString, Set.Set ByteString, JobKind)
data Result = Result !ByteString !(Either SomeException (Outcome [Dependency]))

data RuntimeEvent = Cancelled | Finished | Progress Result | Stalled [ByteString]

data Runtime = Runtime
  { rtSpecs :: !(TVar (Map.Map ByteString JobSpec))
  , rtQueue :: !(TQueue Result)
  , rtActive :: !(TVar (Map.Map ByteString (ThreadId, MVar ())))
  , rtFailures :: !(TVar (Map.Map ByteString SomeException))
  , rtKeepGoing :: !Bool
  , rtCancelled :: !(TVar Bool)
  , rtShared :: !(Maybe Shared)
  -- ^ HS-12: the process-wide shared job limit, if this request runs under one.
  }

-- The callback creates a newly discovered job, or adds its wanted outputs
-- to an existing job. It never starts a builder; only step's Start does.
runScheduled :: Int -> Maybe Int -> Bool -> (ByteString -> Set.Set ByteString -> JobKind -> IO JobSpec) -> [JobSpec] -> IO ()
runScheduled slots downloadSlots keepGoing discover initialSpecs = runScheduledWithCancel slots downloadSlots keepGoing discover initialSpecs (atomically retry)
runScheduledWithCancel :: Int -> Maybe Int -> Bool -> (ByteString -> Set.Set ByteString -> JobKind -> IO JobSpec) -> [JobSpec] -> IO () -> IO ()
runScheduledWithCancel = runScheduledShared Nothing
runScheduledShared :: Maybe Shared -> Int -> Maybe Int -> Bool -> (ByteString -> Set.Set ByteString -> JobKind -> IO JobSpec) -> [JobSpec] -> IO () -> IO ()
runScheduledShared shared slots downloadSlots keepGoing discover initialSpecs cancel = do
  state <- foldM add (initialState (max 0 slots) downloadSlots keepGoing) initialSpecs
  runtime <- Runtime <$> newTVarIO Map.empty <*> newTQueueIO
    <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> pure keepGoing <*> newTVarIO False <*> pure shared
  forM_ initialSpecs (register runtime)
  watcher <- forkIO $ cancel >> atomically (writeTVar (rtCancelled runtime) True)
  dispatch runtime state `onException` uninterruptibleMask_ (cancelActive runtime)
    `finally` killThread watcher
  where
    add state spec = either (throwIO . storeError) pure (addJob (jobId spec) (jobKind spec) [] state)

    register runtime spec = atomically $ writeTVar (rtSpecs runtime) =<<
      Map.insertWith unionWanted (jobId spec) spec <$> readTVar (rtSpecs runtime)
    unionWanted new old = old { jobWanted = Set.union (jobWanted old) (jobWanted new) }

    dispatch runtime state = do
      let (next, actions) = step Tick state
      forM_ actions (perform runtime)
      event <- atomically $ do
        stopped <- readTVar (rtCancelled runtime)
        active <- readTVar (rtActive runtime)
        let unfinished = Map.filter (\job -> status job == Waiting || status job == Running) (jobs next)
        if stopped
          then pure Cancelled
          else if Map.null unfinished && Map.null active
            then pure Finished
            else do
              queued <- tryReadTQueue (rtQueue runtime)
              case queued of
                Just result -> pure (Progress result)
                Nothing | Map.null active -> pure (Stalled (Map.keys unfinished))
                Nothing -> retry
      case event of
        Cancelled -> do
          uninterruptibleMask_ (cancelActive runtime)
          throwIO (storeError "client disconnected during build")
        Finished -> finish runtime
        Progress result -> handleResult runtime next result >>= dispatch runtime
        Stalled waiting -> throwIO (storeError ("build cannot continue; waiting jobs: " <> C.unpack (C.intercalate ", " waiting)))

    finish runtime = do
      failures <- Map.elems <$> atomically (readTVar (rtFailures runtime))
      case failures of
        [] -> pure ()
        exception:_ -> throwIO (if rtKeepGoing runtime then keepGoingError exception else originalError exception)

    handleResult runtime state (Result name result) = do
      atomically $ writeTVar (rtActive runtime) =<< Map.delete name <$> readTVar (rtActive runtime)
      let (next, actions) = case result of
            Left _ -> step (FailedEvent name) state
            Right Done -> step (Completed name) state
            Right (Need required) -> step (NeedsDependencies name [path | (path, _, _) <- required]) state
      case result of
        Left exception -> do
          atomically $ writeTVar (rtFailures runtime) =<<
            Map.insert name exception <$> readTVar (rtFailures runtime)
          forM_ actions (perform runtime)
          unless (rtKeepGoing runtime) $ uninterruptibleMask_ $ do
            cancelActive runtime
            throwIO (originalError exception)
          pure next
        Right Done -> forM_ actions (perform runtime) >> pure next
        Right (Need required) -> do
          next <- either (throwIO . storeError) pure
            (addDependencyJobsWithKinds [(path, kind) | (path, _, kind) <- required] next)
          forM_ required $ \(dependency, wanted, dependencyKind) -> do
            known <- Map.member dependency <$> atomically (readTVar (rtSpecs runtime))
            if known
              then atomically $ writeTVar (rtSpecs runtime) =<<
                Map.adjust (\spec -> spec { jobWanted = Set.union (jobWanted spec) wanted }) dependency <$> readTVar (rtSpecs runtime)
              else discover dependency wanted dependencyKind >>= register runtime
          forM_ actions (perform runtime)
          pure next

    perform runtime (Start name) = do
      specs <- atomically $ readTVar (rtSpecs runtime)
      case Map.lookup name specs of
        Nothing -> throwIO (storeError "scheduler started an unknown job")
        Just spec -> do
          done <- newEmptyMVar
          start <- newEmptyMVar
          worker <- forkIO $ do
            takeMVar start
            (do
              -- HS-12: admit this job against the process-wide shared job limit
              -- before it runs, so the daemon-wide build-max-jobs bounds all
              -- clients together.  Acquired in the worker (not the dispatch
              -- loop) so the loop stays free to process completions that
              -- release slots.  Released once acquired, even if the job fails.
              result <- case rtShared runtime of
                Nothing -> try (jobRun spec (jobWanted spec))
                Just shared -> do
                  acquireSlot shared
                  (try (jobRun spec (jobWanted spec))) `finally` releaseSlot shared
              atomically $ writeTQueue (rtQueue runtime) (Result name result))
              `finally` (void (tryPutMVar done ()))
          atomically $ do
            active <- readTVar (rtActive runtime)
            writeTVar (rtActive runtime) (Map.insert name (worker, done) active)
          putMVar start ()
    perform runtime (Fail name) = do
      let message = "build of `" <> name <> "' failed because an input failed"
      atomically $ writeTVar (rtFailures runtime) =<<
        Map.insert name (toException (StoreError message 1)) <$> readTVar (rtFailures runtime)
    perform _ (Finish _) = pure ()
    perform _ (ReportFailure _) = pure ()

    cancelActive runtime = do
      active <- atomically $ do
        current <- readTVar (rtActive runtime)
        writeTVar (rtActive runtime) Map.empty
        pure (Map.elems current)
      forM_ active $ \(worker, done) -> do
        killThread worker
        takeMVar done

originalError :: SomeException -> StoreError
originalError exception = case fromException exception of
  Just stored -> stored
  Nothing -> StoreError (C.pack (show exception)) 1

keepGoingError :: SomeException -> StoreError
keepGoingError exception = (originalError exception) { storeErrorStatus = 100 }
