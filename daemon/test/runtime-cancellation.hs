{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
-- Runtime cancellation is owned by dispatch, not by a watcher that can be
-- killed halfway through the active-job list. Also exercise idle stalls.
module Main (main) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forever, unless)
import qualified Data.ByteString.Char8 as C
import qualified Data.Set as Set
import Goonix.Build.Runtime
import Goonix.Build.Scheduler
import Goonix.Store.ReadOnly
import System.Exit (die)
import System.Timeout (timeout)

check :: String -> Bool -> IO ()
check name condition = unless condition (die ("FAIL: " ++ name))

main :: IO ()
main = do
  started <- newMVar (0 :: Int)
  stopped <- newMVar (0 :: Int)
  cancelledSignal <- newEmptyMVar
  let spec name = JobSpec name Set.empty BuildJob $ \_ -> do
        modifyMVar_ started (\n -> pure (n + 1))
        (forever (threadDelay 1000000)) `onException` modifyMVar_ stopped (\n -> pure (n + 1))
  result <- newEmptyMVar
  _ <- forkIO $ do
    r <- try (runScheduledWithCancel 2 Nothing False (\_ _ _ -> die "unexpected discovery")
      [spec "left", spec "right"] (readMVar cancelledSignal)) :: IO (Either SomeException ())
    putMVar result r
  let waitForBoth n = do
        count <- readMVar started
        if count == 2 then pure () else threadDelay 10000 >> waitForBoth n
  startedCount <- timeout 3000000 (waitForBoth 0)
  check "both workers start before cancellation" (startedCount == Just ())
  putMVar cancelledSignal ()
  cancelled <- timeout 3000000 (takeMVar result)
  check "cancelled request throws" (case cancelled of
    Nothing -> False
    Just (Left _) -> True
    Just (Right ()) -> False)
  check "both workers started" =<< (== 2) <$> readMVar started
  check "both workers cleaned up" =<< (== 2) <$> readMVar stopped

  let stalled = JobSpec "stalled" Set.empty BuildJob (const (pure Done))
  idle <- try (runScheduled 0 Nothing False (\_ _ _ -> pure stalled) [stalled]) :: IO (Either StoreError ())
  check "idle unfinished request errors" (case idle of
    Left (StoreError message _) -> C.isInfixOf "waiting jobs: stalled" message
    Right () -> False)
  putStrLn "runtime cancellation and stalled-job errors: PASS"
