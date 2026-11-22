{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- Regression: an unsafe sqlite3_step busy-handler sleep must not freeze the
-- daemon's other threads.  Two SQLite handles in ONE process (as two client
-- connections, or a connection and a build goal, each open their own handle)
-- contend for the WAL write lock.  While handle A holds an uncommitted write
-- transaction, handle B's insert hits SQLITE_BUSY and sqlite3_step sleeps in the
-- busy handler.  If that call is `ccall unsafe' it holds its GHC capability for
-- the whole sleep; the next GC needs every capability to stop, so the thread that
-- must run A's commit cannot run, and the allocating loop is stopped too.  B then
-- sleeps its full busy_timeout and fails with DatabaseBusy, and the whole process
-- is stopped meanwhile.  With `ccall safe' the sleep runs on its own OS thread,
-- the capability is released, GC proceeds, A commits, and B's step succeeds.
--
-- Run with +RTS -A1m -N (small allocation area forces frequent GC; -N gives the
-- runtime several capabilities).  Three threads:
--   A: begin immediate + insert (holds the WAL write lock), waits ~2s, commits.
--   B: inserts on a SECOND handle; must succeed (not DatabaseBusy).
--   L: a pure allocating loop; must finish well under A's hold time + B's timeout.
-- PASS when B's insert succeeds AND L finishes within the budget.  FAILS on the
-- unsafe-call tree (B DatabaseBusy and/or L frozen), PASSES with the safe calls.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, fromException, try)
import Control.Monad (unless)
import Data.IORef (newIORef, readIORef, writeIORef)
import Goonix.Store.Database
  ( DatabaseBusy (..), Value (..)
  , closeDatabase, execute, openReadWrite, queryValues )
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- A's hold time before committing, and the wall budget for the allocating loop.
-- The loop budget is well under A's hold (2s) plus B's busy_timeout (60s): if the
-- process is frozen at a GC the loop cannot finish inside it.
holdMicros :: Int
holdMicros = 2000000

loopBudgetSeconds :: Double
loopBudgetSeconds = 1.5

-- A pure allocating loop: builds a fresh list each iteration so the nursery
-- (-A1m) fills and GC runs often.  Returns a checksum so it cannot be optimised
-- away.  No IO inside, so it only stops when a GC cannot get every capability.
allocLoop :: Int -> Int
allocLoop n = go n 0
  where
    go 0 !acc = acc
    go k !acc = go (k - 1) (acc + sum [1 .. 50 :: Int])

main :: IO ()
main = do
  args <- getArgs
  let dbPath = case args of
        (p : _) -> p
        [] -> "/tmp/sqlite-contention-regression.sqlite"
  -- Two independent handles to one WAL database, as two connections.
  a <- openReadWrite dbPath
  b <- openReadWrite dbPath
  execute a "create table if not exists t (x integer);" []
  execute a "delete from t;" []

  aReady <- newEmptyMVar      -- A holds the write lock
  aDone <- newEmptyMVar       -- A has committed
  bResult <- newEmptyMVar     -- B's insert outcome
  loopDone <- newIORef False
  loopSeconds <- newIORef (0 :: Double)

  -- Thread A: hold an uncommitted write transaction for ~2s, then commit.
  _ <- forkIO $ do
    execute a "begin immediate;" []
    execute a "insert into t values (1);" []
    putMVar aReady ()
    threadDelay holdMicros
    execute a "commit;" []
    putMVar aDone ()

  -- Wait until A actually holds the lock before B and L start.
  takeMVar aReady

  -- Thread L: the allocating loop, timed.  It must finish within the budget even
  -- though A holds the lock for 2s and B is sleeping in its busy handler.
  _ <- forkIO $ do
    start <- getMonotonicTime
    let !checksum = allocLoop 200000
    -- Force the checksum so the work is really done before we stop the clock.
    unless (checksum >= 0) (hPutStrLn stderr "impossible")
    end <- getMonotonicTime
    writeIORef loopSeconds (end - start)
    writeIORef loopDone True

  -- Thread B: insert on the second handle while A holds the lock.  With safe
  -- calls the busy handler sleeps on its own OS thread, A commits at ~2s, and
  -- this insert succeeds.  With unsafe calls the capability is held, GC stops
  -- A's commit, and this fails with DatabaseBusy after the full timeout.
  _ <- forkIO $ do
    r <- try (execute b "insert into t values (2);" []) :: IO (Either SomeException ())
    putMVar bResult r

  -- The main thread waits for B (bounded by the daemon's 60s busy_timeout) and
  -- for A's commit.  It allocates while waiting, so it too would freeze at a GC
  -- if a capability were held in an unsafe call.
  bOutcome <- takeMVar bResult
  takeMVar aDone
  -- Give the loop a moment to record its result if it finished.
  threadDelay 200000
  lDone <- readIORef loopDone
  lSecs <- readIORef loopSeconds

  -- Verify both rows are present (B's insert really committed).
  rows <- queryValues a "select x from t order by x;" []
  let haveB = [Integer 2] `elem` rows

  closeDatabase a
  closeDatabase b

  let bOk = case bOutcome of
        Right () -> True
        Left e -> case fromException e :: Maybe DatabaseBusy of
          Just _ -> False
          Nothing -> False
  hPutStrLn stderr ("B insert: " ++ either show (const "ok") bOutcome)
  hPutStrLn stderr ("allocating loop: " ++ (if lDone then show lSecs ++ "s" else "DID NOT FINISH"))
  hPutStrLn stderr ("rows: " ++ show rows)

  let pass = bOk && haveB && lDone && lSecs < loopBudgetSeconds
  if pass
    then hPutStrLn stderr "SQLITE_CONTENTION_PASS (B insert succeeded, allocating loop within budget)"
    else do
      hPutStrLn stderr "SQLITE_CONTENTION_FAIL"
      exitFailure