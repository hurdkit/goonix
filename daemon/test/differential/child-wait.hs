{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BangPatterns #-}

-- Regression: the nonblocking child wait reaps correctly without a blocking waitpid.
-- waitForSandbox / finishOffload used getProcessStatus True False pid, a BLOCKING
-- waitpid that holds the calling thread's GHC capability until the child exits.
-- Goonix.Build.Wait.waitProcessStatusNonBlocking polls with WNOHANG + threadDelay,
-- releasing the capability between polls (the file-lock wait pattern).
--
-- NOTE on the freeze: on this GHC (9.10.3, -threaded) a single blocking waitpid does
-- NOT measurably stop-the-world even at -N2 — the RTS reschedules runnable Haskell
-- threads onto free capabilities during GC (measured: allocating loop ~0.04s while a
-- blocking waitpid waits for a 3s child, at -N2/-N4/-N16).  So this is a correctness
-- regression for the nonblocking wait, not a freeze demonstration; the poll is the
-- defensive choice the reviewer asked for (never hold a capability in a blocking
-- wait), consistent with the socket and sqlite fixes whose freezes ARE reproducible.
--
-- PASS when the nonblocking poll reaps a child that exits 0 (Just (Exited 0)), reaps
-- a child that exits 3 (Just (Exited 3)), and an allocating loop runs while it waits.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (unless)
import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Clock (getMonotonicTime)
import Goonix.Build.Wait (waitProcessStatusNonBlocking)
import System.Exit (ExitCode (..))
import System.Posix.Process (ProcessStatus (..), forkProcess, executeFile)
import System.Posix.Types (ProcessID)
import System.IO (hPutStrLn, stderr)

allocLoop :: Int -> Int
allocLoop n = go n 0
  where go 0 !acc = acc
        go k !acc = go (k-1) (acc + sum [1..50 :: Int])

-- Fork a child that sleeps 2s then exits with the given code.
sleepChild :: Int -> IO ProcessID
sleepChild code = forkProcess $ do
  executeFile "/bin/sh" False ["-c", "sleep 2; exit " ++ show code] Nothing

main :: IO ()
main = do
  -- An allocating loop runs while the nonblocking poll waits for a 2s child.
  done <- newIORef False
  secs <- newIORef (0 :: Double)
  _ <- forkIO $ do
    s <- getMonotonicTime
    let !c = allocLoop 50000
    unless (c >= 0) (hPutStrLn stderr "x")
    e <- getMonotonicTime
    writeIORef secs (e - s)
    writeIORef done True
  pid0 <- sleepChild 0
  status0 <- waitProcessStatusNonBlocking pid0
  pid3 <- sleepChild 3
  status3 <- waitProcessStatusNonBlocking pid3
  threadDelay 200000
  d <- readIORef done
  l <- readIORef secs
  hPutStrLn stderr ("child-wait poll: exit0=" ++ show status0 ++ " exit3=" ++ show status3)
  hPutStrLn stderr ("child-wait poll: allocating loop " ++ show l ++ "s (finished=" ++ show d ++ ")")
  let ok = status0 == Just (Exited ExitSuccess)
           && status3 == Just (Exited (ExitFailure 3))
           && d && l < 1.0
  if ok
    then hPutStrLn stderr "CHILD_WAIT_PASS (nonblocking poll reaps correctly; loop runs while waiting)"
    else do
      hPutStrLn stderr "CHILD_WAIT_FAIL"
      fail "child-wait regression failed"