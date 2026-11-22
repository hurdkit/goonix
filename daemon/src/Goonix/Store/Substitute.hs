{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Substitute
  ( SubstitutableInfo
  , substitutablePaths
  , substitutableInfo
  , substitutableInfos
  , substitutePath
  , packSettings
  ) where

import Control.Exception (SomeException, bracket, catch, throwIO)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Goonix.Store.ReadOnly (StoreError (..), storeError)
import Goonix.Store.Config (ServerConfig (..))
import Goonix.Store.Settings
import System.IO (Handle, hClose, hFlush)
import System.Posix.IO.ByteString (createPipe, closeFd, fdToHandle, setFdOption, FdOption (CloseOnExec), fdRead)
import System.Posix.Process (getProcessStatus)
import System.Posix.Signals (sigTERM, signalProcess)
import System.Posix.Types (CPid (..), Fd (..), ProcessID)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)

type SubstitutableInfo = (ByteString, ByteString, [ByteString], Word64, Word64)

-- | The helper's pipes and pid.  @agentReply@ is fd 4 (the reply channel);
-- @agentLog@ is the helper's merged stdout/stderr (diagnostics); @agentReplyFd@
-- and @agentLogFd@ are their raw descriptors for the select loop.  The Agent
-- also carries the @emit@ callback that forwards diagnostics to the client.
data Agent = Agent
  { agentInput :: !Handle
  , agentReply :: !Handle
  , agentLog :: !Handle
  , agentReplyFd :: !Fd
  , agentLogFd :: !Fd
  , agentPid :: !ProcessID
  , agentEmit :: !(ByteString -> IO ())
  }

foreign import ccall unsafe "goonix_spawn_helper"
  c_spawn_helper :: CString -> CString -> CInt -> CInt -> CInt -> CString -> Ptr CInt -> IO CInt

-- | Wait until either descriptor is readable (C++ select over the reply and log
-- pipes, local-store.cc:799-809).  Bit 0 = reply ready, bit 1 = log ready.
foreign import ccall unsafe "goonix_select_two"
  c_select_two :: CInt -> CInt -> IO CInt

withAgent :: ServerConfig -> Settings -> ByteString -> (ByteString -> IO ()) -> (Agent -> IO a) -> IO a
withAgent config settings argument emit action = bracket start stop action
  where
    start = do
      (inputRead, inputWrite) <- createPipe
      (logRead, logWrite) <- createPipe
      (replyRead, replyWrite) <- createPipe
      mapM_ (\fd -> setFdOption fd CloseOnExec True) [inputRead, inputWrite, logRead, logWrite, replyRead, replyWrite]
      pid <- withCString (C.unpack (configGuixProgram config)) $ \program ->
        withCString (C.unpack argument) $ \argument' ->
          B.useAsCString (packSettings settings) $ \options -> alloca $ \pidPointer -> do
            result <- c_spawn_helper program argument' (fdNumber inputRead) (fdNumber logWrite) (fdNumber replyWrite) options pidPointer
            if result < 0 then throwIO (storeError "cannot spawn substitute helper") else fromIntegral <$> peek pidPointer
      closeFd inputRead
      closeFd logWrite
      closeFd replyWrite
      input <- fdToHandle inputWrite
      output <- fdToHandle replyRead
      logOutput <- fdToHandle logRead
      pure (Agent input output logOutput replyRead logRead pid emit)
    stop agent = do
      hClose (agentInput agent) `catchAny` pure ()
      signalProcess sigTERM (agentPid agent) `catchAny` pure ()
      _ <- getProcessStatus True False (agentPid agent)
      hClose (agentReply agent) `catchAny` pure ()
      hClose (agentLog agent) `catchAny` pure ()
      pure ()

fdNumber :: Fd -> CInt
fdNumber (Fd value) = value

packSettings :: Settings -> ByteString
packSettings settings = B.concat [key <> "=" <> value <> "\n" | (key, value) <- Map.toAscList (values settings)]

substitutablePaths :: ServerConfig -> Settings -> (ByteString -> IO ()) -> [ByteString] -> IO [ByteString]
substitutablePaths config settings emit paths
  | null paths = pure []
  | otherwise = withAgent config settings "--query" emit $ \agent -> do
      sendLine agent ("have" <> foldMap (" " <>) paths <> " ")
      readPaths agent []

substitutableInfo :: ServerConfig -> Settings -> (ByteString -> IO ()) -> ByteString -> IO (Maybe (ByteString, [ByteString], Word64, Word64))
substitutableInfo config settings emit path = do
  infos <- substitutableInfos config settings emit [path]
  pure $ case infos of
    [(_, deriver, references, downloadSize, narSize)] -> Just (deriver, references, downloadSize, narSize)
    _ -> Nothing

substitutableInfos :: ServerConfig -> Settings -> (ByteString -> IO ()) -> [ByteString] -> IO [SubstitutableInfo]
substitutableInfos config settings emit paths
  | null paths = pure []
  | otherwise = withAgent config settings "--query" emit $ \agent -> do
      sendLine agent ("info" <> foldMap (" " <>) paths <> " ")
      readInfos agent []

substitutePath :: ServerConfig -> Settings -> (ByteString -> IO ()) -> ByteString -> ByteString -> IO (Either ByteString (ByteString, Word64))
substitutePath config settings emit path destination = withAgent config settings "--substitute" emit $ \agent -> do
  sendLine agent ("substitute " <> path <> " " <> destination)
  status <- receiveLine agent
  case C.words status of
    ("success":hash:size:_) -> case reads (C.unpack size) of
      [(number, "")] -> pure (Right (hash, number))
      _ -> pure (Left "invalid nar size from substituter")
    _ -> pure (Left status)

readPaths :: Agent -> [ByteString] -> IO [ByteString]
readPaths agent acc = do
  line <- receiveLine agent
  if B.null line then pure (reverse acc) else readPaths agent (line:acc)

readInfos :: Agent -> [SubstitutableInfo] -> IO [SubstitutableInfo]
readInfos agent acc = do
  path <- receiveLine agent
  if B.null path then pure (reverse acc) else do
    deriver <- receiveLine agent
    count <- readCount agent
    references <- mapM (const (receiveLine agent)) [1 .. count]
    downloadSize <- readCount agent
    narSize <- readCount agent
    readInfos agent ((path, deriver, references, fromIntegral downloadSize, fromIntegral narSize):acc)

sendLine :: Agent -> ByteString -> IO ()
sendLine agent line = do
  B.hPutStr (agentInput agent) line
  B.hPutStr (agentInput agent) "\n"
  hFlush (agentInput agent)

-- | Read one reply line from the reply pipe (fd 4) while draining the log pipe,
-- exactly as the C++ getLineFromSubstituter (local-store.cc:792-842): select on
-- both descriptors, completely drain the log (forwarding each chunk to the
-- client as C++ writeToStderr does) before dealing with the reply, then read
-- reply bytes until a newline.  Draining the log in the same loop is what keeps
-- a helper that writes more than the pipe buffer of diagnostics before its
-- reply from deadlocking: the log never fills, so the helper never blocks in
-- write(), so the reply arrives.  Doing it in ONE thread (not a concurrent
-- drainer) paces the client forwarding with the reply read, so the diagnostic
-- stream cannot fill the client socket faster than the client reads it and
-- back-pressure the helper through the log pipe.
receiveLine :: Agent -> IO ByteString
receiveLine agent = go [] False
  where
    replyFd = agentReplyFd agent
    logFd = agentLogFd agent
    -- logDone: the log pipe reached EOF (helper exited).  Stop selecting on it
    -- so a ready reply is read first; a helper that replies then exits must not
    -- be reported as "died unexpectedly" just because its log closed first.
    go acc logDone = do
      mask <- c_select_two (fdNumber replyFd) (if logDone then fdNumber replyFd else fdNumber logFd)
      if mask < 0
        then throwIO (storeError "waiting for input from the substituter")
        else do
          let logReady = not logDone && mask .&. 2 /= 0
              replyReady = mask .&. 1 /= 0
          if logReady && not replyReady
            then do
              bytes <- fdRead logFd 4096
              if B.null bytes
                then go acc True
                else agentEmit agent bytes >> go acc False
            else if replyReady
              then do
                byte <- fdRead replyFd 1
                if B.null byte
                  then throwIO (storeError "`guix substitute' died unexpectedly")
                  else case C.head byte of
                    '\n' -> pure (B.concat (reverse acc))
                    _ -> go (byte : acc) logDone
              else go acc logDone

readCount :: Agent -> IO Int
readCount agent = do
  line <- receiveLine agent
  case reads (C.unpack line) of
    [(number, "")] -> pure number
    _ -> throwIO (storeError ("integer expected from stream: " ++ C.unpack line))

catchAny :: IO a -> IO a -> IO a
catchAny action fallback = catch action (\(_ :: SomeException) -> fallback)