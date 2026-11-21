{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
-- | HS-12 shared-scheduler properties (DECISIONS.md point 2, 00-plan.md §7).
-- One job limit and one goal per derivation across the clients of one daemon.
-- These exercise the process-wide Shared scheduler directly: several clients'
-- jobs share one slot limit, and two clients asking for the same derivation
-- cause one build (the second attaches to the first's goal).
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, newMVar, modifyMVar_, readMVar)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, forM_, replicateM, unless, void)
import qualified Data.ByteString.Char8 as C
import Data.IORef (newIORef, atomicModifyIORef', readIORef)
import Goonix.Build.Shared
import Goonix.Store.ReadOnly (StoreError (..), storeError)
import System.Exit (die)
import System.Timeout (timeout)

check :: String -> Bool -> IO ()
check name condition = unless condition (die ("FAIL: " ++ name))

main :: IO ()
main = do
  -- One job limit across clients: with a shared limit of 2, four clients each
  -- running one job never have more than 2 running at once, and all complete.
  shared <- newShared 2
  running <- newIORef (0 :: Int)
  peak <- newIORef (0 :: Int)
  done <- newEmptyMVar
  let clientJob i = do
        acquireSlot shared
        atomicModifyIORef' running (\n -> (n + 1, ()))
        n <- readIORef running
        atomicModifyIORef' peak (\p -> (max p n, ()))
        threadDelay 20000
        atomicModifyIORef' running (\n -> (n - 1, ()))
        releaseSlot shared
        putMVar done ()
  forM_ [1 :: Int .. 4] (\i -> void (forkIO (clientJob i)))
  forM_ [1 :: Int .. 4] (\_ -> takeMVar done)
  peakCount <- readIORef peak
  check "shared job limit bounds all clients together" (peakCount <= 2)
  check "shared job limit reaches the limit" (peakCount == 2)
  finalRunning <- runningJobs shared
  check "all shared slots released" (finalRunning == 0)

  -- One goal per derivation: two clients ask for the same derivation while the
  -- first is building; the builder runs ONCE and both clients succeed.
  shared2 <- newShared 4
  builds <- newIORef (0 :: Int)
  release <- newEmptyMVar
  let build = do
        atomicModifyIORef' builds (\n -> (n + 1, ()))
        takeMVar release   -- hold the goal open so the second client attaches
  firstDone <- newEmptyMVar
  secondDone <- newEmptyMVar
  _ <- forkIO $ (withGoal shared2 "same.drv" build) >> putMVar firstDone ()
  -- Let the first client start the goal, then attach a second client.
  threadDelay 20000
  _ <- forkIO $ (withGoal shared2 "same.drv" build) >> putMVar secondDone ()
  threadDelay 20000
  -- The second client must be waiting on the first's goal, not building.
  buildCountMid <- readIORef builds
  check "second client attaches, does not start a second build" (buildCountMid == 1)
  putMVar release ()
  takeMVar firstDone
  takeMVar secondDone
  buildCount <- readIORef builds
  check "two clients same derivation cause one build" (buildCount == 1)

  -- Only SUCCESS is shared.  The starter's build fails (its own settings); the
  -- starter gets the failure.  A waiter whose goal failed runs its OWN attempt
  -- with its own settings, which succeeds — as a waiter on the output lock would
  -- in C++.  So the builder runs twice (starter fails, waiter succeeds).
  shared3 <- newShared 4
  failBuilds <- newIORef (0 :: Int)
  failRelease <- newEmptyMVar
  -- The starter's attempt fails; the waiter's own attempt succeeds.  The first
  -- call (starter) throws; the second call (waiter re-run) succeeds.
  let failing = do
        n <- atomicModifyIORef' failBuilds (\n -> (n + 1, n))
        if n == 0
          then do takeMVar failRelease; throwIO (storeError "starter goal failed")
          else pure ()
  f1 <- newEmptyMVar
  f2 <- newEmptyMVar
  let runFailing out = do
        r <- try (withGoal shared3 "fail.drv" failing)
        putMVar out (r :: Either SomeException ())
  _ <- forkIO (runFailing f1)
  threadDelay 20000
  _ <- forkIO (runFailing f2)
  threadDelay 20000
  putMVar failRelease ()
  r1 <- takeMVar f1
  r2 <- takeMVar f2
  check "starter gets its own goal failure" (isLeft r1)
  check "waiter re-runs its own attempt and succeeds" (isRight r2)
  failCount <- readIORef failBuilds
  check "failed goal: starter fails, waiter builds again" (failCount == 2)

  -- A client arriving after the goal ended re-runs (output valid -> no-op).
  shared4 <- newShared 4
  lateBuilds <- newIORef (0 :: Int)
  withGoal shared4 "late.drv" (atomicModifyIORef' lateBuilds (\n -> (n + 1, ())))
  withGoal shared4 "late.drv" (atomicModifyIORef' lateBuilds (\n -> (n + 1, ())))
  lateCount <- readIORef lateBuilds
  check "client after goal end re-runs the (valid) build" (lateCount == 2)

  putStrLn "shared scheduler properties: PASS"
  where
    isLeft (Left _) = True
    isLeft _ = False
    isRight (Right _) = True
    isRight _ = False