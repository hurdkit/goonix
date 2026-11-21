{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- Accepted sockets serialize protocol frames with one mutex. A writer that
-- is blocked on a dead peer must not leave a queue preventing disconnect.
module Goonix.Store.Socket
  ( Socket
  , listenUnix
  , listenTcp
  , acceptSocket
  , fromFd
  , closeSocket
  , readSocket
  , writeSocket
  , peerUid
  , isTcp
  , isListening
  , waitForDisconnect
  , setCloseOnExec
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay, threadWaitRead)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (throwIO)
import Control.Monad (forever)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Foreign.C.String (CString, withCString)
import Foreign.C.Error (Errno (..), getErrno)
import Foreign.C.Types (CInt (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import System.IO.Error (userError)
import System.Posix.ByteString (RawFilePath)
import System.Posix.IO (closeFd, setFdOption, FdOption (CloseOnExec))
import System.Posix.IO.ByteString (fdRead, fdWrite)
import System.Posix.Types (Fd (..))

data Socket = Socket !Fd !(Maybe (MVar ()))

foreign import ccall unsafe "goonix_listen_unix" c_listen_unix :: CString -> IO CInt
foreign import ccall unsafe "goonix_listen_tcp" c_listen_tcp :: CString -> CString -> IO CInt
foreign import ccall safe "goonix_accept" c_accept :: CInt -> IO CInt
foreign import ccall unsafe "goonix_peer_uid" c_peer_uid :: CInt -> Ptr CUInt -> IO CInt
foreign import ccall unsafe "goonix_is_tcp" c_is_tcp :: CInt -> IO CInt
foreign import ccall unsafe "goonix_is_listening" c_is_listening :: CInt -> IO CInt
foreign import ccall unsafe "goonix_peek_socket" c_peek_socket :: CInt -> IO CInt

listenUnix :: RawFilePath -> IO Socket
listenUnix path = (\fd -> Socket (Fd fd) Nothing) <$> do
  fd <- B.useAsCString path c_listen_unix
  if fd < 0 then socketError "cannot bind/listen on Unix socket" else pure fd

listenTcp :: String -> String -> IO Socket
listenTcp host service = (\fd -> Socket (Fd fd) Nothing) <$> withCString host (\host' -> withCString service $ \service' -> do
  fd <- c_listen_tcp host' service'
  if fd < 0 then socketError "cannot bind/listen on TCP socket" else pure fd)

acceptSocket :: Socket -> IO Socket
acceptSocket (Socket (Fd fd) _) = do
  client <- c_accept fd
  if client < 0 then do
    errno <- getErrno
    socketError ("cannot accept client: errno=" ++ show (case errno of Errno number -> number))
    else do
      lock <- newMVar ()
      pure (Socket (Fd client) (Just lock))

fromFd :: Fd -> Socket
fromFd fd = Socket fd Nothing

closeSocket :: Socket -> IO ()
closeSocket (Socket fd _) = closeFd fd

readSocket :: Socket -> Int -> IO ByteString
readSocket (Socket fd _) size = fdRead fd (fromIntegral size)

writeSocket :: Socket -> ByteString -> IO ()
writeSocket (Socket fd writer) bytes = case writer of
  Nothing -> writeFrame fd bytes
  Just lock -> withMVar lock (const (writeFrame fd bytes))

-- Wait for a hang-up without consuming a protocol byte. threadWaitRead is
-- managed by the GHC runtime, so killThread also stops this wait promptly.
-- If a client sends input while an operation is running, leave it queued and
-- sleep until the operation's owner stops this watcher.
waitForDisconnect :: Socket -> IO ()
waitForDisconnect (Socket fd@(Fd raw) _) = do
  threadWaitRead fd
  state <- c_peek_socket raw
  case state of
    0 -> pure ()
    3 -> pure ()
    1 -> forever (threadDelay maxBound)
    _ -> waitForDisconnect (Socket fd Nothing)

writeFrame :: Fd -> ByteString -> IO ()
writeFrame _ bytes | B.null bytes = pure ()
writeFrame fd bytes = do
  written <- fdWrite fd bytes
  if written == 0 then socketError "cannot write to socket"
    else writeFrame fd (B.drop (fromIntegral written) bytes)

peerUid :: Socket -> IO (Maybe CUInt)
peerUid (Socket (Fd fd) _) = alloca $ \uid -> do
  result <- c_peer_uid fd uid
  if result == 0 then Just <$> peek uid else pure Nothing

isTcp :: Socket -> IO Bool
isTcp (Socket (Fd fd) _) = (== 1) <$> c_is_tcp fd

isListening :: Socket -> IO Bool
isListening (Socket (Fd fd) _) = (== 1) <$> c_is_listening fd

setCloseOnExec :: Socket -> Bool -> IO ()
setCloseOnExec (Socket fd _) enabled = setFdOption fd CloseOnExec enabled

socketError :: String -> IO a
socketError message = throwIO (userError message)
