{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Regression for DeepScan.readDiagnostic's timeout.
--
-- The bug: readDiagnostic wrapped only `hGetContents handle` in `timeout`.
-- hGetContents is LAZY — it returns a thunk immediately without blocking, so the
-- timeout always succeeded instantly and the real blocking read happened later
-- in `evaluate (length bounded)`, OUTSIDE any deadline.  A helper that keeps the
-- pipe open and never exits therefore blocked the build thread FOREVER; the
-- configured goonix-deep-scan-timeout was dead code.  C++ polls with a deadline
-- and kills the child (deep-scan.cc:84-111).
--
-- The fix forces the bounded string INSIDE the timeout, so the deadline bounds
-- the read and a hung helper is killed when the limit expires.
--
-- This test holds a pipe's write end open (a hung helper, no EOF) and calls
-- readDiagnostic with a 1-second limit, under an outer 8-second guard.  BEFORE
-- the fix readDiagnostic never returns, the outer guard fires -> FAIL.  AFTER
-- the fix readDiagnostic returns the "exceeded its 1 second limit" error in ~1s
-- -> PASS.  It also checks the normal path: a helper that writes a diagnostic and
-- closes the pipe yields that diagnostic.
module Main (main) where

import Control.Exception (SomeException, try)
import Data.List (isInfixOf)
import Goonix.Store.DeepScan (readDiagnostic)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hClose, hPutStr, hFlush)
import System.Posix.IO.ByteString (createPipe, fdToHandle, closeFd)
import System.Posix.Types (CPid (..))
import System.Timeout (timeout)

main :: IO ()
main = do
  ok1 <- hungHelperIsKilledAtTheDeadline
  ok2 <- normalDiagnosticIsRead
  if ok1 && ok2 then exitSuccess else exitFailure

-- A pipe whose write end stays open: no EOF ever arrives.  readDiagnostic must
-- return (with the timeout error) within its 1s limit, not block forever.
hungHelperIsKilledAtTheDeadline :: IO Bool
hungHelperIsKilledAtTheDeadline = do
  (readFd, writeFd) <- createPipe
  readHandle <- fdToHandle readFd
  -- Keep writeFd open in this process: the helper "hangs", never closes stdout.
  -- Outer guard: 8s.  The inner readDiagnostic limit is 1s.  Before the fix the
  -- inner timeout never fires (lazy hGetContents), so this outer guard fires.
  result <- timeout (8 * 1000000)
    (try (readDiagnostic readHandle 1 (CPid 999999)) :: IO (Either SomeException String))
  -- Clean up the held write end and the read handle.
  closeFd writeFd
  hClose readHandle
  case result of
    Nothing -> do
      putStrLn "FAIL: readDiagnostic blocked past the 8s guard (timeout was ineffective; lazy hGetContents bug)"
      pure False
    Just (Left ex) ->
      if "exceeded its 1 second limit" `isInfixOf` show ex
        then do putStrLn "PASS: hung helper killed at the 1s deadline"; pure True
        else do putStrLn ("FAIL: unexpected error: " ++ show ex); pure False
    Just (Right s) -> do
      putStrLn ("FAIL: readDiagnostic returned a diagnostic from a hung helper: " ++ show s)
      pure False

-- Normal path: write a diagnostic, close the write end (EOF), read it back.
normalDiagnosticIsRead :: IO Bool
normalDiagnosticIsRead = do
  (readFd, writeFd) <- createPipe
  readHandle <- fdToHandle readFd
  writeHandle <- fdToHandle writeFd
  hPutStr writeHandle "self-token\t7\t/gnu/store/x.drv\n"
  hFlush writeHandle
  hClose writeHandle   -- EOF
  result <- timeout (5 * 1000000)
    (try (readDiagnostic readHandle 5 (CPid 999999)) :: IO (Either SomeException String))
  hClose readHandle
  case result of
    Just (Right s) | s == "self-token\t7\t/gnu/store/x.drv\n" -> do
      putStrLn "PASS: normal diagnostic read intact"
      pure True
    other -> do
      putStrLn ("FAIL: normal diagnostic path: " ++ show other)
      pure False