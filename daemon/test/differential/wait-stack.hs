{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BangPatterns #-}

-- Regression: waitProcessStatusNonBlocking must not accumulate memory per poll.
-- Before the fix, `go` recursed INSIDE alloca's body: alloca's keepAlive# holds the
-- pinned status buffer (and the poll's stack frame) alive until the body returns,
-- so every 10ms poll added a live pinned buffer + frame, none freed until the child
-- exits (~360,000 per hour of build; waitForSandbox / finishOffload run for the whole
-- build, in every concurrent build at once).  After the fix alloca is OUTSIDE the
-- loop: one buffer, `go` a real tail call, live memory flat.
--
-- Discriminator (calibrated): while waiting on a child that sleeps 12s (~1200 polls),
-- sample gcdetails_live_bytes after a major GC at t=2s (warm-up done) and t=11s.
-- Before the fix live bytes GROW ~7 KB/s (each poll's buffer stays live: ~60 KB over
-- the window); after the fix the growth is only the sampler's own small baseline
-- (< ~10 KB).  PASS when the wait reaps the child's exit code AND live growth over the
-- window is under 24 KiB.  Also run under a tight stack (-K64k): on RTSes where the
-- per-poll frames are not reclaimed this overflows before the fix; on GHC 9.10.3 the
-- measurable effect is the pinned/live growth below.  Requires +RTS -T (GC stats).
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import GHC.Stats (getRTSStats, getRTSStatsEnabled, gcdetails_live_bytes, gc)
import Goonix.Build.Wait (waitProcessStatusNonBlocking)
import System.Exit (ExitCode (..))
import System.Mem (performMajorGC)
import System.Posix.Process (ProcessStatus (..), forkProcess, executeFile)
import System.IO (hPutStrLn, stderr)

liveNow :: IO Integer
liveNow = do
  performMajorGC
  s <- getRTSStats
  pure (fromIntegral (gcdetails_live_bytes (gc s)))

main :: IO ()
main = do
  enabled <- getRTSStatsEnabled
  if not enabled
    then do
      hPutStrLn stderr "WAIT_STACK_FAIL (GC stats not enabled; run with +RTS -T)"
      fail "wait-stack regression needs +RTS -T"
    else pure ()
  pid <- forkProcess (executeFile "/bin/sh" False ["-c", "sleep 12; exit 7"] Nothing)
  done <- newEmptyMVar
  _ <- forkIO $ do
    r <- try (waitProcessStatusNonBlocking pid)
    putMVar done r
  threadDelay 2000000              -- warm-up: let the sampler/RTS settle
  first <- liveNow
  hPutStrLn stderr ("wait-stack: t=2s live=" ++ show first)
  threadDelay 9000000              -- ~900 more polls
  lastS <- liveNow
  hPutStrLn stderr ("wait-stack: t=11s live=" ++ show lastS)
  r <- takeMVar done
  let growth = lastS - first
  hPutStrLn stderr ("wait-stack: live growth over window = " ++ show growth ++ " bytes")
  case r of
    Left e -> do
      hPutStrLn stderr ("WAIT_STACK_FAIL (wait died, likely stack overflow under -K64k: "
                        ++ show (e :: SomeException) ++ ")")
      fail "wait-stack regression failed"
    Right status
      | status /= Just (Exited (ExitFailure 7)) -> do
          hPutStrLn stderr ("WAIT_STACK_FAIL (wrong exit status: " ++ show status ++ ")")
          fail "wait-stack regression failed"
      | growth >= 24576 -> do
          hPutStrLn stderr ("WAIT_STACK_FAIL (live memory grew " ++ show growth
                            ++ " bytes during the wait — per-poll pinned buffers held alive)")
          fail "wait-stack regression failed"
      | otherwise ->
          hPutStrLn stderr "WAIT_STACK_PASS (exit code reaped; live memory flat — one buffer, tail-call poll)"