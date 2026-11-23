{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- Regression (reviewer point 2): finishOffload must drain ALL of a hook's output
-- and return, even when the hook writes more than the 64 KiB pipe buffer with
-- pauses.  The output fd is non-blocking, so fdRead hits EAGAIN whenever the pipe
-- is momentarily empty.  Before the fix, drainFd's `catch \_ -> pure B.empty`
-- treated EAGAIN as EOF and stopped draining early: later bursts were lost, and
-- once >64 KiB was pending the helper blocked in write(), so
-- waitProcessStatusNonBlocking never returned and finishOffload hung — the very
-- deadlock the drain exists to prevent.  After the fix drainFd waits through the
-- IO manager on EAGAIN and only a 0-byte read is EOF.
--
-- Spawn the real offload-flood-helper.sh via startOffloadHook (a real child, so
-- waitProcessStatusNonBlocking reaps it), requestOffload (it accepts), acceptOffload,
-- then finishOffload while counting emitted bytes and timing it (+RTS -A1m -N).
-- PASS when finishOffload returns within a bounded time AND every byte the helper
-- wrote reaches emit (256 KiB).  FAILS before the fix (hang or bytes lost).
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef (newIORef, readIORef, modifyIORef')
import GHC.Clock (getMonotonicTime)
import Goonix.Build.Offload
  (Hook (..), HookReply (..), startOffloadHook, requestOffload, acceptOffload, finishOffload, stopHook)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  let helper = case args of
        (h:_) -> h
        [] -> "daemon/test/differential/offload-flood-helper.sh"
  emitted <- newIORef (0 :: Int)
  let emit b = modifyIORef' emitted (+ B.length b)
  hook <- startOffloadHook (C.pack helper) "x86_64-linux" 3600 False 86400
  s <- getMonotonicTime
  r <- try (do
        reply <- requestOffload hook emit True "x86_64-linux" "/gnu/store/x.drv" []
        case reply of
          HookAccept -> pure ()
          other -> fail ("helper did not accept: " ++ show other)
        acceptOffload hook [] []
        _ <- finishOffload hook emit
        pure ())
  e <- getMonotonicTime
  n <- readIORef emitted
  stopHook hook
  let elapsed = e - s
      expected = 256 * 1024   -- 8 bursts x 512 lines x 64 bytes = 262144 exactly
  hPutStrLn stderr ("offload-flood: elapsed=" ++ show elapsed ++ "s emitted=" ++ show n ++ " bytes (expected " ++ show expected ++ ") result=" ++ show (r :: Either SomeException ()))
  case r of
    Right () | n == expected && elapsed < 30 ->
      hPutStrLn stderr "OFFLOAD_FLOOD_PASS (finishOffload returned; every byte drained despite EAGAIN pauses)"
    Right () -> do
      hPutStrLn stderr "OFFLOAD_FLOOD_FAIL (returned but lost bytes or took too long)"
      fail "offload-flood regression failed"
    Left err -> do
      hPutStrLn stderr ("OFFLOAD_FLOOD_FAIL (finishOffload raised: " ++ show err ++ ")")
      fail "offload-flood regression failed"