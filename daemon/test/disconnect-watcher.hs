{-# LANGUAGE GHC2024 #-}
-- Regression: disconnect watching must not consume a later protocol request.
module Main (main) where

import Control.Concurrent
import Control.Exception
import Control.Monad (unless, void)
import qualified Data.ByteString.Char8 as C
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr)
import Goonix.Store.Socket
import System.Exit (die)
import System.Posix.IO.ByteString (closeFd, fdRead, fdWrite)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

foreign import ccall unsafe "socketpair" c_socketpair :: CInt -> CInt -> CInt -> Ptr CInt -> IO CInt
foreign import ccall unsafe "shutdown" c_shutdown :: CInt -> CInt -> IO CInt

pair :: IO (Fd, Fd)
pair = allocaArray 2 $ \fds -> do
  result <- c_socketpair 1 1 0 fds
  unless (result == 0) (die "socketpair failed")
  [left, right] <- peekArray 2 fds
  pure (Fd left, Fd right)

check :: String -> Bool -> IO ()
check name condition = unless condition (die ("FAIL: " ++ name))

watch :: Fd -> IO (ThreadId, MVar (Either SomeException ()))
watch fd = do
  done <- newEmptyMVar
  thread <- forkIO (try (waitForDisconnect (fromFd fd)) >>= putMVar done)
  pure (thread, done)

quiet :: MVar a -> IO Bool
quiet done = threadDelay 200000 >> isEmptyMVar done

main :: IO ()
main = do
  (server, client) <- pair
  (thread, done) <- watch server
  quiet done >>= check "watcher waits before input"
  _ <- fdWrite client (C.pack "next request")
  quiet done >>= check "input is not a hang-up"
  fdRead server 64 >>= check "input remains queued" . (== C.pack "next request")
  stopped <- timeout 1000000 (killThread thread >> takeMVar done)
  check "killThread stops the watcher" (maybe False (either (const True) (const False)) stopped)

  _ <- fdWrite client (C.pack "x")
  (pendingThread, pendingDone) <- watch server
  quiet pendingDone >>= check "already queued input is not a hang-up"
  killThread pendingThread >> void (takeMVar pendingDone)
  fdRead server 64 >>= check "already queued input remains queued" . (== C.pack "x")

  (_, closedDone) <- watch server
  quiet closedDone >>= check "watcher waits before close"
  closeFd client
  closed <- timeout 2000000 (takeMVar closedDone)
  check "close ends the watch" (maybe False (either (const False) (const True)) closed)
  closeFd server

  (halfServer, halfClient@(Fd rawClient)) <- pair
  (_, halfDone) <- watch halfServer
  _ <- c_shutdown rawClient 1
  halfClosed <- timeout 2000000 (takeMVar halfDone)
  check "write-side close ends the watch" (maybe False (either (const False) (const True)) halfClosed)
  closeFd halfClient >> closeFd halfServer
  putStrLn "disconnect watcher: PASS"
