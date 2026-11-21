{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Transparent Unix-socket proxy with a deterministic protocol transcript.
-- Usage: goonix-wire-proxy UPSTREAM-SOCKET DOWNSTREAM-SOCKET TRANSCRIPT
module Main (main) where

import Control.Concurrent (ThreadId, forkFinally, killThread, myThreadId)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  , withMVar
  )
import Control.Monad (unless)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , IOException
  , SomeException
  , bracket
  , catch
  , finally
  , fromException
  , mask
  , mask_
  , throwIO
  , throwTo
  , try
  )
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Word (Word64)
import Goonix.Store.Wire
import Network.Socket (Family (AF_UNIX), SockAddr (SockAddrUnix), Socket, SocketType (Stream), accept, bind, close, connect, listen, shutdown, ShutdownCmd (ShutdownSend), socket, unsafeFdSocket, withSocketsDo)
import Network.Socket.ByteString (recv, sendAll)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.Posix.ByteString (RawFilePath)
import System.Posix.Env.ByteString (getArgs)
import System.Posix.Files.ByteString (removeLink)
import GHC.Conc (threadWaitRead, threadWaitWrite)
import System.Posix.IO (OpenMode (WriteOnly), closeFd, creat, defaultFileFlags, dupTo, stdError, stdInput, stdOutput, trunc)
import System.Posix.Process (executeFile, forkProcess, getProcessStatus)
import System.Posix.IO (createPipe)
import System.Environment (lookupEnv)
import System.Posix.IO.ByteString (fdWrite, openFd)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM)
import System.Posix.Types (Fd (..), ProcessID)
import System.Timeout (timeout)

newtype Stop = Stop ThreadId
  deriving Show
instance Exception Stop

main :: IO ()
main = do
  args <- getArgs
  case args of
    [upstream, downstream, transcript] -> runProxy upstream downstream transcript
    _ -> do
      putErr "usage: goonix-wire-proxy UPSTREAM-SOCKET DOWNSTREAM-SOCKET TRANSCRIPT\n"
      exitWith (ExitFailure 2)

runProxy :: RawFilePath -> RawFilePath -> RawFilePath -> IO ()
runProxy upstream downstream transcript = withSocketsDo $
  bracket (openTranscript transcript) closeRecorder $ \output ->
    bracket (listenUnix downstream) (\socket' -> close socket' `finally` removeIfPresent downstream) $ \listener ->
      bracket (newMVar []) stopClients $ \clients ->
        mask $ \restore -> do
          tid <- myThreadId
          old <- installHandler sigTERM (Catch (throwTo tid (Stop tid))) Nothing
          restore (acceptLoop listener upstream output clients)
            `catch` \e -> case fromException e of
              Just (Stop _) -> pure ()
              Nothing -> throwIO e
            `finally` void (installHandler sigTERM old Nothing)

data Client = Client
  { clientThread :: !ThreadId
  , clientDone :: !(MVar ())
  }

acceptLoop :: Socket -> RawFilePath -> Recorder -> MVar [Client] -> IO ()
acceptLoop listener upstream output clients = do
  next <- newIORef 0
  let acceptNext = do
        waitSocket listener threadWaitRead
        clientFd <- fst <$> accept listener
        number <- atomicModifyIORef' next (\n -> (n + 1, n + 1))
        mask_ $ do
          done <- newEmptyMVar
          tid <- forkFinally
            (handleClient upstream output number clientFd)
            (finishClient clients clientFd done)
          modifyClients clients (Client tid done :)
        acceptNext
  acceptNext

finishClient :: MVar [Client] -> Socket -> MVar () -> Either SomeException () -> IO ()
finishClient clients clientFd done result = do
  close clientFd
  tid <- myThreadId
  modifyClients clients (filter ((/= tid) . clientThread))
  case result of
    Left e | Just ThreadKilled <- fromException e -> pure ()
           | otherwise -> reportException "client" e
    Right () -> pure ()
  putMVar done ()

handleClient :: RawFilePath -> Recorder -> Word64 -> Socket -> IO ()
handleClient upstream output number clientFd =
  bracket (connectUnix upstream) close $ \serverFd ->
    relay output number clientFd serverFd

-- Killing a lightweight thread cancels its socket readiness wait.  Do not
-- close a live descriptor from another thread: the kernel may reuse its number.
stopClients :: MVar [Client] -> IO ()
stopClients clients = do
  active <- readMVar clients
  forM_ active $ \client -> do
    killThread (clientThread client)
    _ <- timeout 1000000 (takeMVar (clientDone client))
    pure ()

modifyClients :: MVar [Client] -> ([Client] -> [Client]) -> IO ()
modifyClients clients f = modifyMVar clients (\current -> pure (f current, ()))

relay :: Recorder -> Word64 -> Socket -> Socket -> IO ()
relay recorder number client server = do
  state <- newMVar (newConnection, 0, 0)
  _ <- forkFinally
    (pipe ClientToDaemon "c2s" client server state)
    (\result -> case result of
      Right () -> shutdown server ShutdownSend `catchIO` \_ -> pure ()
      Left e | Just ThreadKilled <- fromException e -> pure ()
             | otherwise -> close server)
  pipe DaemonToClient "s2c" server client state
  where
    pipe direction label input output state = do
      waitSocket input threadWaitRead
      bytes <- recv input 32768
      if B.null bytes
        then flushEof direction label state
        else do
          (frames, offset) <- modifyMVar state $ \(old, c2sOffset, s2cOffset) ->
            let (new, frames) = feedBytes direction old bytes
                offset = case direction of ClientToDaemon -> c2sOffset; DaemonToClient -> s2cOffset
                offset' = offset + fromIntegral (B.length bytes)
                next = case direction of ClientToDaemon -> (new, offset', s2cOffset); DaemonToClient -> (new, c2sOffset, offset')
            in pure (next, (frames, offset))
          writeFrames recorder number label offset frames
          sendBytes output bytes
          pipe direction label input output state
    flushEof direction label state = modifyMVar state $ \(old, c2sOffset, s2cOffset) -> do
      let (new, frames) = endOfStream direction old
          offset = case direction of ClientToDaemon -> c2sOffset; DaemonToClient -> s2cOffset
      writeFrames recorder number label offset frames
      pure ((new, c2sOffset, s2cOffset), ())

waitSocket :: Socket -> (Fd -> IO ()) -> IO ()
waitSocket socket' wait = unsafeFdSocket socket' >>= wait . Fd

sendBytes :: Socket -> ByteString -> IO ()
sendBytes socket' bytes = waitSocket socket' threadWaitWrite >> sendAll socket' bytes

newtype Recorder = Recorder (MVar RecorderSink)

data RecorderSink = RecorderSink !Fd !(Maybe ProcessID)

openTranscript :: RawFilePath -> IO Recorder
openTranscript path = do
  compress <- lookupEnv "GOONIX_WIRE_GZIP"
  fd <- if compress == Just "1" then pure stdOutput
    else openFd path WriteOnly defaultFileFlags { trunc = True, creat = Just 0o600 }
  sink <- if compress == Just "1"
    then do
      (readEnd, writeEnd) <- createPipe
      child <- forkProcess $ do
        closeFd writeEnd
        _ <- dupTo readEnd stdInput
        out <- openFd path WriteOnly defaultFileFlags { trunc = True, creat = Just 0o600 }
        _ <- dupTo out stdOutput
        closeFd out
        closeFd readEnd
        executeFile "gzip" True ["-c"] Nothing
      closeFd readEnd
      pure (RecorderSink writeEnd (Just child))
    else pure (RecorderSink fd Nothing)
  Recorder <$> newMVar sink

closeRecorder :: Recorder -> IO ()
closeRecorder (Recorder lock) = withMVar lock $ \(RecorderSink fd child) -> do
  closeQuietly fd
  forM_ child $ \pid -> void (getProcessStatus True False pid)

-- The raw hex line is the byte-fidelity record.  Decoded fields are advisory
-- and never alter what is forwarded or which bytes the transcript retains.
writeFrames :: Recorder -> Word64 -> ByteString -> Word64 -> [Frame] -> IO ()
writeFrames (Recorder lock) number label initial frames = withMVar lock $ \(RecorderSink fd _) -> go fd initial frames
  where
    go _ _ [] = pure ()
    go fd offset (frame : rest) = do
      let raw = frameBytes frame
          end = offset + fromIntegral (B.length raw)
          prefix = ascii number <> " " <> label <> " " <> ascii offset <> " " <> ascii end <> " "
          body = drop 1 (frameLines frame)
          text = prefix <> frameHeader frame <> "\n" <> B.concat ["  " <> line <> "\n" | line <- body]
      writeAll fd text
      go fd end rest

ascii :: Show a => a -> ByteString
ascii = C.pack . show

listenUnix :: RawFilePath -> IO Socket
listenUnix path = do
  unless (B.length path <= 107) (throwIO (userError "Unix socket path is too long"))
  socket' <- socket AF_UNIX Stream 0
  bind socket' (SockAddrUnix (C.unpack path)) `catchIO` \e -> close socket' >> throwIO e
  listen socket' 128
  pure socket'

connectUnix :: RawFilePath -> IO Socket
connectUnix path = do
  socket' <- socket AF_UNIX Stream 0
  connect socket' (SockAddrUnix (C.unpack path)) `catchIO` \e -> close socket' >> throwIO e
  pure socket'

writeAll :: Fd -> ByteString -> IO ()
writeAll fd bytes
  | B.null bytes = pure ()
  | otherwise = do
      n <- fdWrite fd bytes
      writeAll fd (B.drop (fromIntegral n) bytes)

catchIO :: IO a -> (IOException -> IO a) -> IO a
catchIO = catch

closeQuietly :: Fd -> IO ()
closeQuietly fd = void (try (closeFd fd) :: IO (Either IOException ()))

removeIfPresent :: RawFilePath -> IO ()
removeIfPresent path = void (try (removeLink path) :: IO (Either IOException ()))

reportException :: ByteString -> SomeException -> IO ()
reportException context e = putErr (context <> ": " <> C.pack (show e) <> "\n")

putErr :: ByteString -> IO ()
putErr bytes = void (try (writeAll stdError bytes) :: IO (Either IOException ()))
