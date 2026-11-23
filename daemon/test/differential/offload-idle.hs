{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- Regression: the offload hook reply read must go through the IO manager, not a
-- raw blocking hGetLine that holds a capability while the helper is silent.
-- receiveLine (Offload.hs) reads the helper's output pipe; the pipe is non-blocking
-- and receiveLine waits with threadWaitRead.  Before the fix it was C.hGetLine on a
-- blocking Handle, which on the non-blocking pipe throws EAGAIN (crash) or, on a
-- blocking pipe, holds the capability.
--
-- Construct a Hook over a socketpair whose peer stays silent for 3s, run receiveLine
-- while a pure allocating loop runs (+RTS -A1m -N).  PASS when the loop finishes well
-- under the silence AND receiveLine survives (parked, then reads the line the peer
-- finally sends) — not crashed on EAGAIN.
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
import Goonix.Build.Offload (Hook (..), receiveLine)
import System.Posix.IO (setFdOption, FdOption (NonBlockingRead))
import System.Posix.IO.ByteString (fdWrite, createPipe)
import System.Posix.Types (Fd(..))
import System.IO (hPutStrLn, stderr, stdin)

foreign import ccall unsafe "socketpair"
  c_socketpair :: CInt -> CInt -> CInt -> Ptr CInt -> IO CInt

allocLoop :: Int -> Int
allocLoop n = go n 0
  where go 0 !acc = acc
        go k !acc = go (k-1) (acc + sum [1..50 :: Int])

pair :: IO (Fd, Fd)
pair = allocaBytes 8 $ \p -> do
  r <- c_socketpair 1 1 0 p
  unless (r == 0) (fail "socketpair failed")
  a <- peekByteOff p 0 :: IO CInt
  b <- peekByteOff p 4 :: IO CInt
  pure (Fd a, Fd b)

main :: IO ()
main = do
  (outFd, peerFd) <- createPipe
  setFdOption outFd NonBlockingRead True
  -- Match production: the output stays a RAW fd (no fdToHandle); receiveLine reads
  -- hookOutputFd via fdRead + threadWaitReadSTM.  A dummy Handle fills hookInput.
  stopped <- newEmptyMVar
  let hook = Hook { hookInput = stdin, hookOutputFd = outFd
                  , hookBuilder = stdin, hookPid = 0, hookStopped = stopped }
  ready <- newEmptyMVar
  survived <- newIORef False
  done <- newIORef False
  secs <- newIORef (0 :: Double)
  _ <- forkIO $ do
    putMVar ready ()
    _ <- receiveLine hook
    writeIORef survived True
  takeMVar ready
  threadDelay 50000
  _ <- forkIO $ do
    s <- getMonotonicTime
    let !c = allocLoop 50000
    unless (c >= 0) (hPutStrLn stderr "x")
    e <- getMonotonicTime
    writeIORef secs (e - s)
    writeIORef done True
  threadDelay 3000000                 -- peer silent 3s
  _ <- fdWrite peerFd "# accept\n"    -- now receiveLine can return
  threadDelay 300000
  d <- readIORef done
  sv <- readIORef survived
  l <- readIORef secs
  hPutStrLn stderr ("offload-idle: loop " ++ show l ++ "s, receiveLine survived=" ++ show sv)
  if d && l < 1.0 && sv
    then hPutStrLn stderr "OFFLOAD_IDLE_PASS (receiveLine waited through the IO manager; loop ran)"
    else do
      hPutStrLn stderr "OFFLOAD_IDLE_FAIL (loop frozen, or receiveLine crashed on EAGAIN)"
      fail "offload-idle regression failed"