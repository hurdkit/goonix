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

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay, threadWaitRead, threadWaitWrite)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, catch, throwIO)
import Control.Monad (forever)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Foreign.C.String (CString, withCString)
import Foreign.C.Error (Errno (..), getErrno, eAGAIN, eWOULDBLOCK, eINTR)
import Foreign.C.Types (CInt (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import System.IO.Error (userError)
import GHC.IO.Exception (ioe_errno)
import System.Posix.ByteString (RawFilePath)
import System.Posix.IO (closeFd, setFdOption, FdOption (CloseOnExec, NonBlockingRead))
import System.Posix.IO.ByteString (fdRead, fdWrite)
import System.Posix.Types (Fd (..))

data Socket = Socket !Fd !(Maybe (MVar ()))

foreign import ccall unsafe "goonix_listen_unix" c_listen_unix :: CString -> IO CInt
foreign import ccall unsafe "goonix_socket_errno" c_socket_errno :: IO CInt
foreign import ccall unsafe "goonix_listen_tcp" c_listen_tcp :: CString -> CString -> IO CInt
foreign import ccall safe "goonix_accept" c_accept :: CInt -> IO CInt
foreign import ccall unsafe "goonix_peer_uid" c_peer_uid :: CInt -> Ptr CUInt -> IO CInt
foreign import ccall unsafe "goonix_is_tcp" c_is_tcp :: CInt -> IO CInt
foreign import ccall unsafe "goonix_is_listening" c_is_listening :: CInt -> IO CInt
foreign import ccall unsafe "goonix_peek_socket" c_peek_socket :: CInt -> IO CInt

listenUnix :: RawFilePath -> IO Socket
listenUnix path = (\fd -> Socket (Fd fd) Nothing) <$> do
  result <- B.useAsCString path c_listen_unix
  if result >= 0
    then pure result
    else do
      errno <- c_socket_errno
      let file = C.unpack path
          errnoText = ": errno=" ++ show (case errno of CInt number -> number)
          message = case result of
            -1 -> "cannot create Unix domain socket" ++ errnoText
            -2 -> "creating directory for socket '" ++ file ++ "'" ++ errnoText
            -3 -> "cannot change current directory to socket directory of '" ++ file ++ "'" ++ errnoText
            -4 -> "socket file name '" ++ file ++ "' is too long"
            -5 -> "cannot bind to socket '" ++ file ++ "'" ++ errnoText
            -6 -> "cannot change current directory back from socket '" ++ file ++ "'" ++ errnoText
            -7 -> "cannot listen on socket '" ++ file ++ "'" ++ errnoText
            _ -> "cannot bind/listen on Unix socket '" ++ file ++ "'" ++ errnoText
      socketError message

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
      -- Non-blocking so readSocket/writeFrame can wait through the IO manager
      -- instead of holding a capability in a raw blocking read/write.
      setFdOption (Fd client) NonBlockingRead True
      pure (Socket (Fd client) (Just lock))

fromFd :: Fd -> Socket
fromFd fd = Socket fd Nothing

closeSocket :: Socket -> IO ()
closeSocket (Socket fd _) = closeFd fd

-- Read up to @size@ bytes, waiting through the GHC IO manager when the socket is
-- non-blocking and empty.  A raw blocking fdRead would hold this thread's GHC
-- capability until the client sends something; the next GC needs every capability
-- to stop, so one idle client would freeze every other client and build in the
-- process.  threadWaitRead releases the capability while parked (and is
-- interruptible).  A blocking descriptor (e.g. an activation socket) still reads
-- directly; accepted client sockets are set non-blocking in acceptSocket.
readSocket :: Socket -> Int -> IO ByteString
readSocket (Socket fd _) size = go
  where
    go = do
      r <- (Just <$> fdRead fd (fromIntegral size)) `catch` wouldBlock
      case r of
        Just bytes -> pure bytes
        Nothing -> threadWaitRead fd >> go
    wouldBlock :: IOException -> IO (Maybe ByteString)
    wouldBlock e
      | isWouldBlock e = pure Nothing
      | otherwise = throwIO e
    isWouldBlock e =
      let errno = ioe_errno e
      in errno == Just (case eAGAIN of Errno n -> n)
         || errno == Just (case eWOULDBLOCK of Errno n -> n)

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

-- Write all bytes, waiting through the IO manager when a non-blocking socket's
-- send buffer is full (a client that is not reading).  A raw blocking fdWrite
-- would hold the capability for as long as the client stalls; threadWaitWrite
-- releases it.  A blocking descriptor writes directly.
writeFrame :: Fd -> ByteString -> IO ()
writeFrame _ bytes | B.null bytes = pure ()
writeFrame fd bytes = do
  written <- (Just <$> fdWrite fd bytes) `catch` wouldBlock
  case written of
    Nothing -> threadWaitWrite fd >> writeFrame fd bytes
    Just n
      | n == 0 -> socketError "cannot write to socket"
      | otherwise -> writeFrame fd (B.drop (fromIntegral n) bytes)
  where
    wouldBlock :: IOException -> IO (Maybe a)
    wouldBlock e
      | isWouldBlock e = pure Nothing
      | otherwise = throwIO e
    isWouldBlock e =
      let errno = ioe_errno e
      in errno == Just (case eAGAIN of Errno n -> n)
         || errno == Just (case eWOULDBLOCK of Errno n -> n)

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
