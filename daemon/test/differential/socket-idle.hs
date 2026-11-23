{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- Regression: a client that does not cooperate must not freeze the daemon's other
-- threads.  The accepted client socket is non-blocking; readSocket/writeSocket must
-- wait through the GHC IO manager (threadWaitRead/threadWaitWrite), not a raw
-- blocking fdRead/fdWrite that holds its capability until the client acts.  A raw
-- blocking call holds the capability, the next GC needs every capability to stop,
-- and one idle or non-reading client freezes every other client and build.
--
-- Two cases, each on the daemon's OWN readSocket/writeSocket over an AF_UNIX
-- socketpair, with a pure allocating loop timed on a monotonic clock (+RTS -A1m -N):
--   READ  (idle client): the peer sends nothing for 4s while readSocket waits.
--   WRITE (client stops reading mid-reply): the peer never reads, so the send
--         buffer fills and writeSocket waits on a full socket buffer.
-- PASS when, in BOTH cases, the loop finishes well under the stall AND the
-- daemon-side read/write thread SURVIVES (it is still waiting, not crashed).  Before
-- the fix a raw fdRead/fdWrite on the non-blocking socket throws EAGAIN and kills
-- the thread (a crash, not a wait) — detected by the survival check — or, on a
-- blocking socket, freezes the loop.  After the fix the thread waits through the IO
-- manager and the loop runs free.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, catch)
import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.IORef (newIORef, readIORef, writeIORef)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekByteOff)
import GHC.Clock (getMonotonicTime)
import Goonix.Store.Socket (fromFd, readSocket, writeSocket, closeSocket)
import System.Posix.IO (setFdOption, FdOption (NonBlockingRead))
import System.Posix.IO.ByteString (fdWrite, fdRead)
import System.Posix.Types (Fd(..))
import System.IO (hPutStrLn, stderr)

foreign import ccall unsafe "socketpair"
  c_socketpair :: CInt -> CInt -> CInt -> Ptr CInt -> IO CInt

allocLoop :: Int -> Int
allocLoop n = go n 0
  where go 0 !acc = acc
        go k !acc = go (k-1) (acc + sum [1..50 :: Int])

pair :: IO (Fd, Fd)
pair = allocaBytes 8 $ \p -> do
  r <- c_socketpair 1 1 0 p           -- AF_UNIX = 1, SOCK_STREAM = 1
  unless (r == 0) (fail "socketpair failed")
  a <- peekByteOff p 0 :: IO CInt
  b <- peekByteOff p 4 :: IO CInt
  pure (Fd a, Fd b)

-- Run `stall` in one thread while a pure allocating loop runs in another for ~4s.
-- Returns (loop wall seconds, stall thread still alive at the end of the window).
-- A raw blocking call freezes the loop (large seconds); a raw non-blocking call
-- throws EAGAIN and kills the stall thread (alive = False).  The IO-manager wait
-- keeps the loop fast AND the thread alive (parked).
measure :: IO () -> IO (Double, Bool)
measure stall = do
  ready <- newEmptyMVar
  done <- newIORef False
  secs <- newIORef (0 :: Double)
  alive <- newIORef True
  _ <- forkIO $ do
    putMVar ready ()
    stall
    writeIORef alive False        -- completed (only happens if not stalled)
  takeMVar ready
  threadDelay 50000
  _ <- forkIO $ do
    s <- getMonotonicTime
    let !c = allocLoop 50000
    unless (c >= 0) (hPutStrLn stderr "x")
    e <- getMonotonicTime
    writeIORef secs (e - s)
    writeIORef done True
  threadDelay 4000000
  d <- readIORef done
  a <- readIORef alive
  s <- readIORef secs
  -- alive here means the stall thread has NOT finished; but a crashed thread also
  -- has not finished.  We distinguish crash via a separate survival probe below.
  pure (if d then s else 1e9, a)

main :: IO ()
main = do
  -- READ: idle client.  readSocket waits for a byte the peer sends only after 4s.
  (serverR, peerR) <- pair
  setFdOption serverR NonBlockingRead True
  let serverRead = fromFd serverR
  readSurvived <- newIORef False
  (readSecs, _) <- measure $ do
    _ <- readSocket serverRead 1
    writeIORef readSurvived True   -- reached only if readSocket returned (no crash)
  _ <- fdWrite peerR "x"           -- let a parked readSocket complete
  threadDelay 200000
  readOk <- readIORef readSurvived
  closeSocket serverRead

  -- WRITE: client stops reading mid-reply.  writeSocket fills the send buffer.
  (serverW, peerW) <- pair
  setFdOption serverW NonBlockingRead True
  let serverWrite = fromFd serverW
      big = B.replicate (8 * 1024 * 1024) 65   -- 8 MiB, far over the socket buffer
  writeSurvived <- newIORef False
  (writeSecs, _) <- measure $ do
    writeSocket serverWrite big
    writeIORef writeSurvived True
  -- Drain the peer so a parked writeSocket can finish; a crashed thread cannot.
  _ <- forkIO $ let drain = do
                      b <- fdRead peerW 65536 `catch` \(_ :: IOException) -> pure B.empty
                      unless (B.null b) drain
                in drain
  threadDelay 500000
  writeOk <- readIORef writeSurvived
  closeSocket serverWrite
  closeSocket (fromFd peerW)

  hPutStrLn stderr ("socket-idle READ  (idle client):        loop " ++ show readSecs ++ "s, read survived=" ++ show readOk)
  hPutStrLn stderr ("socket-idle WRITE (client stops reading): loop " ++ show writeSecs ++ "s, write survived=" ++ show writeOk)
  if readSecs < 1.0 && writeSecs < 1.0 && readOk && writeOk
    then hPutStrLn stderr "SOCKET_IDLE_PASS (daemon kept serving for idle and non-reading clients)"
    else do
      hPutStrLn stderr "SOCKET_IDLE_FAIL (loop frozen, or read/write crashed on EAGAIN instead of waiting)"
      fail "socket-idle regression failed"