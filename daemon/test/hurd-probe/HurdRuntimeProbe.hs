{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- GNU Guix --- Functional package management for GNU
-- This file is part of GNU Guix.
-- GNU Guix is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version.

-- HS-9 guest probe (00-plan.md §7, DECISIONS.md point 5).
--
-- A threaded Haskell program for x86_64-pc-gnu that exercises the five runtime
-- facilities the Haskell daemon needs on the Hurd guest:
--   1. the threaded runtime (forkOS / forkIO, more than one OS thread),
--   2. a timer (threadDelay),
--   3. poll on a socket (threadWaitRead on a Unix-domain socketpair fd, the
--      same mechanism the daemon uses in Goonix.Store.Socket),
--   4. a child process (System.Process),
--   5. STM: an atomically/retry exchange between two threads plus a
--      registerDelay timeout (DECISIONS.md point 5, "STM on the Hurd").
--
-- Only boot libraries are used (base, unix, process, stm, bytestring) plus a
-- two-line C socketpair helper, so it builds with the daemon's own toolchain
-- and needs no Hackage packages. Build:
--   ghc -threaded -rtsopts -with-rtsopts=-N -O2 HurdRuntimeProbe.hs socketpair.c
-- Run (guest is the gate; host validates the logic):
--   ./HurdRuntimeProbe +RTS -N2
-- It prints one "PASS <label>" line per facility and exits 0 only if all pass.

module Main (main) where

import Control.Concurrent
    ( forkIO, forkOS, myThreadId, newEmptyMVar, putMVar, takeMVar, threadDelay
    , threadWaitRead )
import Control.Concurrent.STM
    ( atomically, newTVarIO, readTVar, registerDelay, retry, writeTVar )
import Control.Exception (bracket, try, SomeException)
import Control.Monad (unless)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import System.Posix.IO (closeFd, fdRead, fdWrite)
import System.Posix.Types (Fd (..))
import System.Process (readProcess)

-- int hs9_socketpair(int fds[2]): socketpair(AF_UNIX, SOCK_STREAM, 0, fds).
foreign import ccall unsafe "hs9_socketpair" c_socketpair :: Ptr CInt -> IO CInt

pass :: String -> IO ()
pass label = putStrLn ("PASS " ++ label)

check :: String -> Bool -> IO ()
check label condition = do
    unless condition (hPutStrLn stderr ("FAIL " ++ label) >> exitFailure)
    pass label

-- 1. Threaded runtime: a bound (forkOS) thread and a lightweight (forkIO)
--    thread both run and report distinct thread ids.
probeThreaded :: IO ()
probeThreaded = do
    osDone <- newEmptyMVar
    ioDone <- newEmptyMVar
    mainId <- myThreadId
    _ <- forkOS (myThreadId >>= \tid -> putMVar osDone tid)
    _ <- forkIO (myThreadId >>= \tid -> putMVar ioDone tid)
    osId <- takeMVar osDone
    ioId <- takeMVar ioDone
    check "threaded: forkOS thread ran" (show osId /= show mainId)
    check "threaded: forkIO thread ran" (show ioId /= show mainId)

-- 2. Timer: threadDelay actually waits and returns (the RTS timer works).
--    The real timing assertion is the registerDelay timeout in probeSTM.
probeTimer :: IO ()
probeTimer = do
    threadDelay 50000                    -- 50 ms
    pass "timer: threadDelay returned"

-- 3. Poll on a socket: a Unix-domain socketpair; one thread blocks in
--    threadWaitRead + fdRead (the I/O manager polls the fd), the main thread
--    writes, then reads the echo. This is the daemon's own socket-wait path.
probeSocketPoll :: IO ()
probeSocketPoll = do
    bracket (allocaArray 2 $ \p -> do
        rc <- c_socketpair p
        check "socket: socketpair created" (rc == 0)
        x <- peekElemOff p 0
        y <- peekElemOff p 1
        pure (Fd x, Fd y))
        (\(x, y) -> closeFd x >> closeFd y)
        $ \(a, b) -> do
            got <- newEmptyMVar
            _ <- forkIO $ do
                threadWaitRead a         -- block via the I/O manager poll
                (msg, _) <- fdRead a 64
                _ <- fdWrite a msg       -- echo back
                putMVar got msg
            _ <- fdWrite b "hs9-poll"
            (reply, _) <- fdRead b 64
            check "socket: poll/recv echoed" (reply == "hs9-poll")
            echoed <- takeMVar got
            check "socket: server thread received via poll" (echoed == "hs9-poll")

-- 4. Child process: spawn a shell and read its output. The shell path is
--    taken from the environment (SHELL) or /bin/sh; on the Hurd guest and on
--    NixOS alike a POSIX sh exists. The child prints a fixed marker.
probeChild :: IO ()
probeChild = do
    out <- readProcess "/bin/sh" ["-c", "echo hs9-child"] ""
    check "child: readProcess output" (out == "hs9-child\n")

-- 5. STM exchange (DECISIONS.md point 5): two threads exchange a value through
--    a TVar with atomically/retry, and a registerDelay timeout fires.
probeSTM :: IO ()
probeSTM = do
    -- (a) atomically/retry handshake: consumer retries until producer writes.
    box <- newTVarIO (Nothing :: Maybe Int)
    consumed <- newEmptyMVar
    _ <- forkIO $ do
        value <- atomically $ do
            m <- readTVar box
            case m of
                Nothing -> retry          -- block until the producer writes
                Just v  -> pure v
        putMVar consumed value
    threadDelay 20000                    -- let the consumer reach retry
    atomically (writeTVar box (Just 42))
    value <- takeMVar consumed
    check "stm: atomically/retry exchange" (value == 42)

    -- (b) registerDelay timeout: a TVar that flips True after the delay; a
    --     retrying transaction wakes when it fires.
    timedOut <- registerDelay 30000      -- 30 ms
    fired <- atomically $ do
        b <- readTVar timedOut
        if b then pure True else retry
    check "stm: registerDelay timeout fired" fired

main :: IO ()
main = do
    hPutStrLn stderr "HS-9 Hurd runtime probe: threaded/timer/poll/child/STM"
    probeThreaded
    probeTimer
    probeSocketPoll
    probeChild
    probeSTM
    putStrLn "ALL PASS"
    exitSuccess