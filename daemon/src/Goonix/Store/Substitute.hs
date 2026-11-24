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

import Control.Exception (SomeException, bracket, catch, throwIO, finally)
import Control.Concurrent.STM (atomically, orElse)
import GHC.Conc (threadWaitReadSTM)
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
  -- C++ SubstitutionGoal::tryToRun hands the substituter
  -- settings.pack() + "deduplicate=" + (autoOptimiseStore ? "yes" : "no")
  -- (nix/libstore/build.cc:3946-3952), and guix-daemon defaults
  -- autoOptimiseStore to true (nix/nix-daemon/guix-daemon.cc:505).
  -- guix/scripts/substitute.scm:723-725 reads that option and only attempts
  -- FILE-LEVEL substitution when it is set (substitute.scm:507-512).  Without
  -- it the HS daemon silently fetched whole NARs, so tests/guix-ca-files.sh saw
  -- zero /goonix/file/ requests.
  <> "deduplicate=" <> (if settingBool "build-deduplicate" True settings then "yes\n" else "no\n")

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
-- as the C++ getLineFromSubstituter (local-store.cc:792-842): wait for either
-- descriptor, drain the log (forwarding each chunk to the client as C++
-- writeToStderr does) before dealing with the reply, then read reply bytes until
-- a newline.  Draining the log in the same loop is what keeps a helper that writes
-- more than the pipe buffer of diagnostics before its reply from deadlocking: the
-- log never fills, so the helper never blocks in write(), so the reply arrives.
-- Doing it in ONE thread (not a concurrent drainer) paces the client forwarding
-- with the reply read, so the diagnostic stream cannot fill the client socket
-- faster than the client reads it and back-pressure the helper through the log
-- pipe.
--
-- The wait goes through the GHC IO manager (threadWaitReadSTM on both pipes,
-- atomically (log `orElse` reply), log first as C++ drains stderr before stdout),
-- NOT an `unsafe' foreign select().  The daemon
-- is -threaded -N: an unsafe blocking call holds its capability until it returns,
-- and the next GC needs every capability to stop, so a silent helper would freeze
-- every other client and build in the process at its next GC; an unsafe call also
-- cannot take an asynchronous exception (client disconnect, timeout).  The IO
-- manager releases the capability while parked and is interruptible.  Both
-- unregister actions run afterwards even on an exception, so no registration
-- leaks.  This is the one place C++ differs structurally: there each client is its
-- own process, so a blocking select() in one cannot stall the others.
receiveLine :: Agent -> IO ByteString
receiveLine agent = go [] False
  where
    replyFd = agentReplyFd agent
    logFd = agentLogFd agent
    -- Wait until the log pipe is readable, or (when still open) the reply pipe.
    -- Returns True for reply, False for log.  orElse tries the LOG first, as the
    -- C++ getLineFromSubstituter drains stderr before dealing with stdout
    -- (local-store.cc:811-829); if the log is not ready it tries the reply.  Both
    -- registrations are torn down even if the wait is interrupted (async
    -- exception) or throws.
    waitReplyOrLog logDone = do
      (waitReply, unregisterReply) <- threadWaitReadSTM replyFd
      if logDone
        then (atomically waitReply >> pure True) `finally` unregisterReply
        else do
          (waitLog, unregisterLog) <- threadWaitReadSTM logFd
          let wait = atomically ((waitLog >> pure False) `orElse` (waitReply >> pure True))
          wait `finally` (unregisterReply >> unregisterLog)
    -- logDone: the log pipe reached EOF (helper exited).  Stop waiting on it so a
    -- ready reply is read first; a helper that replies then exits must not be
    -- reported as "died unexpectedly" just because its log closed first.
    go acc logDone = do
      replyReady <- waitReplyOrLog logDone
      if not replyReady
        then do
          bytes <- fdRead logFd 4096
          if B.null bytes
            then go acc True
            else agentEmit agent bytes >> go acc False
        else do
          byte <- fdRead replyFd 1
          if B.null byte
            then throwIO (storeError "`guix substitute' died unexpectedly")
            else case C.head byte of
              '\n' -> pure (B.concat (reverse acc))
              _ -> go (byte : acc) logDone

readCount :: Agent -> IO Int
readCount agent = do
  line <- receiveLine agent
  case reads (C.unpack line) of
    [(number, "")] -> pure number
    _ -> throwIO (storeError ("integer expected from stream: " ++ C.unpack line))

catchAny :: IO a -> IO a -> IO a
catchAny action fallback = catch action (\(_ :: SomeException) -> fallback)