{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- Regression: a request to `guix authenticate' must return while another thread
-- of the daemon is busy, and must leave no helper behind.
--
-- The helper answers a request and then waits for the next one; it exits when
-- its input ends.  The daemon used to wait for that exit with the input still
-- open, so the end of input came from the handle's finalizer, at the next
-- garbage collection.  A runtime that has gone idle collects soon, which hid
-- it.  A running build polls its builder every few milliseconds: the runtime
-- is never idle and allocates almost nothing, no collection comes, and the
-- request does not return.  That is how a graph answer that arrived during a
-- build stayed unimported while the build ran.
--
-- The probe keeps one thread waking the way the builder wait does and sends
-- several requests through Goonix.Store.Archive.verifySignature to a stand-in
-- helper that behaves like the real one: one reply, then it reads until its
-- input ends.  PASS when every request returns the helper's reply within the
-- limit and the helper's process is gone when the request returns.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, forever, unless, when)
import qualified Data.ByteString.Char8 as C
import Goonix.Store.Archive (verifySignature)
import System.Directory (doesDirectoryExist, doesFileExist, removeFile)
import System.Environment (getArgs)
import System.Exit (die)
import System.Timeout (timeout)

main :: IO ()
main = do
  [directory] <- getArgs
  let pidFile = directory ++ "/helper.pid"
  -- The builder wait of a running build: wake, look, sleep.
  _ <- forkIO (forever (threadDelay 10000))
  forM_ [1 .. 3 :: Int] $ \request -> do
    present <- doesFileExist pidFile
    when present (removeFile pidFile)
    -- The request runs in a thread of its own: the limit must hold even
    -- where the request sits in a foreign call.
    finished <- newEmptyMVar
    _ <- forkIO (try (verifySignature "signature") >>= putMVar finished)
    reply <- timeout 5000000 (takeMVar finished)
    case reply of
      Nothing -> die ("FAIL: request " ++ show request
        ++ " did not return while another thread kept the runtime busy")
      Just (Left (failure :: SomeException)) ->
        die ("FAIL: request " ++ show request ++ " raised " ++ show failure)
      Just (Right bytes) -> unless (bytes == "abcd") $
        die ("FAIL: request " ++ show request ++ " returned " ++ C.unpack bytes)
    helper <- filter (/= '\n') <$> readFile pidFile
    alive <- doesDirectoryExist ("/proc/" ++ helper)
    when alive $
      die ("FAIL: the helper of request " ++ show request ++ " is still there")
  putStrLn "authenticate while a build polls: PASS"
