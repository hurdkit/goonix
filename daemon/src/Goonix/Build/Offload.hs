{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- The guix offload helper protocol (inventory 4.10).  Helpers are kept
-- separate from the build engine so their transcript is directly testable.
module Goonix.Build.Offload
  ( HookReply (..)
  , Hook (..)
  , HelperStatus (..)
  , startOffloadHook
  , requestOffload
  , acceptOffload
  , finishOffload
  , stopHook
  , receiveLine
  ) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import Control.Exception (IOException, SomeException, bracketOnError, catch, throwIO, finally)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import System.Exit (ExitCode (..))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Goonix.Build.Wait (waitProcessStatusNonBlocking)
import Goonix.Store.ReadOnly (storeError)
import System.IO (Handle, hClose, hFlush)
import System.IO.Error (isEOFError)
import System.Posix.IO.ByteString (createPipe, closeFd, fdToHandle, setFdOption, FdOption (CloseOnExec, NonBlockingRead), fdRead)
import GHC.Conc (threadWaitReadSTM)
import GHC.IO.Exception (ioe_errno)
import Foreign.C.Error (eAGAIN, eWOULDBLOCK, Errno (..))
import System.Posix.Process (ProcessStatus (Exited, Terminated, Stopped))
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Posix.Types (Fd (..), ProcessID, ByteCount)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)

data HookReply = HookDecline | HookPostpone | HookAccept deriving (Eq, Show)

data Hook = Hook
  { hookInput :: !Handle
  , hookOutputFd :: !Fd
  , hookBuilder :: !Handle
  , hookPid :: !ProcessID
  , hookStopped :: !(MVar Bool)
  }

-- Exit 100 is permanent, 101 is a timeout, and other exits/signals are
-- transient.  This is the statusToString distinction used by buildDone.
data HelperStatus = HelperExited !Int | HelperSignalled !Int | HelperAbnormal
  deriving (Eq, Show)

foreign import ccall unsafe "goonix_spawn_offload"
  c_spawn_offload :: CString -> CInt -> CInt -> CInt -> CString -> CString -> CString -> CString -> Ptr CInt -> IO CInt

startOffloadHook :: ByteString -> ByteString -> Int -> Bool -> Int -> IO Hook
startOffloadHook program system silent trace timeout =
  bracketOnError makePipes closePipes $ \(inputRead, inputWrite, outputRead, outputWrite, builderRead, builderWrite) -> do
    mapM_ (\fd -> setFdOption fd CloseOnExec True)
      [inputRead, inputWrite, outputRead, outputWrite, builderRead, builderWrite]
    pid <- withCString (C.unpack program) $ \program' ->
      withCString (C.unpack system) $ \system' ->
        withCString (show silent) $ \silent' ->
          withCString (if trace then "true" else "false") $ \trace' ->
            withCString (show timeout) $ \timeout' -> alloca $ \pidPointer -> do
              result <- c_spawn_offload program' (fdNumber inputRead) (fdNumber outputWrite)
                (fdNumber builderWrite) system' silent' trace' timeout' pidPointer
              if result < 0 then throwIO (storeError "cannot spawn offload helper") else fromIntegral <$> peek pidPointer
    closeFd inputRead
    closeFd outputWrite
    closeFd builderWrite
    -- Non-blocking so receiveLine waits through the IO manager instead of holding
    -- a capability in a raw blocking read while the offload helper is silent.
    -- The output stays a RAW fd (no fdToHandle): a Handle registered on the fd
    -- interferes with the raw-fd threadWaitReadSTM wait (EBADF), as Substitute.hs
    -- also keeps its reply/log pipes as raw fds.
    setFdOption outputRead NonBlockingRead True
    input <- fdToHandle inputWrite
    builder <- fdToHandle builderRead
    stopped <- newMVar False
    pure (Hook input outputRead builder pid stopped)
  where
    makePipes = do
      (inputRead, inputWrite) <- createPipe
      (outputRead, outputWrite) <- createPipe
      (builderRead, builderWrite) <- createPipe
      pure (inputRead, inputWrite, outputRead, outputWrite, builderRead, builderWrite)
    closePipes (inputRead, inputWrite, outputRead, outputWrite, builderRead, builderWrite) =
      forM_ [inputRead, inputWrite, outputRead, outputWrite, builderRead, builderWrite] $ \fd ->
        closeFd fd `catchAny` pure ()

-- Ordinary helper diagnostics are forwarded exactly as lines; only a line
-- beginning with "# " is a reply.  Decline/postpone leave the helper alive
-- for another offer, as worker.hook does in the C++ worker.
requestOffload :: Hook -> (ByteString -> IO ()) -> Bool -> ByteString -> ByteString -> [ByteString] -> IO HookReply
requestOffload hook emit slot platform drv features = do
  sendLine hook (C.pack (if slot then "1" else "0") <> " " <> platform <> " " <> drv <> " " <> C.intercalate "," features)
  replyLine
  where
    replyLine = do
      line <- receiveLine hook
      if "# " `B.isPrefixOf` line
        then case B.drop 2 line of
          "decline" -> pure HookDecline
          "postpone" -> pure HookPostpone
          "accept" -> pure HookAccept
          reply -> throwIO (storeError ("bad hook reply `" ++ C.unpack reply ++ "'"))
        else emit (line <> "\n") >> replyLine

acceptOffload :: Hook -> [ByteString] -> [ByteString] -> IO ()
acceptOffload hook inputs outputs = do
  -- Both lists have a trailing space, even when empty.
  sendLine hook (foldMap (<> " ") inputs)
  sendLine hook (foldMap (<> " ") outputs)
  hClose (hookInput hook)

-- C++ watches fromAgent and builderOut concurrently.  Draining only fd 4
-- would deadlock a helper that fills its stderr pipe before exiting.
finishOffload :: Hook -> (ByteString -> IO ()) -> IO HelperStatus
finishOffload hook emit = do
  agentDrained <- newEmptyMVar
  builderDrained <- newEmptyMVar
  _ <- forkFinally (drainFd (hookOutputFd hook)) (putMVar agentDrained)
  _ <- forkFinally (drain (hookBuilder hook)) (putMVar builderDrained)
  status <- waitProcessStatusNonBlocking (hookPid hook)
  agentResult <- takeMVar agentDrained
  builderResult <- takeMVar builderDrained
  either throwIO pure agentResult
  either throwIO pure builderResult
  pure $ case status of
    Just (Exited ExitSuccess) -> HelperExited 0
    Just (Exited (ExitFailure code)) -> HelperExited code
    Just (Terminated signal _) -> HelperSignalled (fromIntegral signal)
    Just (Stopped _) -> HelperAbnormal
    Nothing -> HelperAbnormal
  where
    drain handle = do
      bytes <- B.hGetSome handle 32768
      unless (B.null bytes) $ emit bytes >> drain handle
    -- The output fd is NON-BLOCKING (startOffloadHook), so fdRead throws EAGAIN
    -- whenever the pipe is momentarily empty — that is NOT EOF.  Treating it as
    -- EOF (the old `catch \_ -> pure B.empty`) stopped the drain early: everything
    -- the helper wrote afterwards was lost, and once it wrote more than the pipe
    -- buffer (64 KiB) it blocked in write(), waitProcessStatusNonBlocking never
    -- returned, and the build hung — the very deadlock this drain prevents.  Wait
    -- through the IO manager on EAGAIN/EWOULDBLOCK (finally-unregister, as
    -- receiveLine) and read again; only a 0-byte read is EOF.
    drainFd fd = do
      bytes <- readSomeNonBlocking fd 32768
      unless (B.null bytes) $ emit bytes >> drainFd fd

stopHook :: Hook -> IO ()
stopHook hook = do
  stopped <- takeMVar (hookStopped hook)
  unless stopped $ do
    closeIgnore (hookInput hook)
    closeFd (hookOutputFd hook) `catchAny` pure ()
    closeIgnore (hookBuilder hook)
    -- Agent::~Agent uses a separate process group and SIGKILL.
    signalProcessGroup sigKILL (hookPid hook) `catchAny` pure ()
    _ <- waitProcessStatusNonBlocking (hookPid hook) `catchAny` pure Nothing
    pure ()
  putMVar (hookStopped hook) True

sendLine :: Hook -> ByteString -> IO ()
sendLine hook line = do
  B.hPutStr (hookInput hook) line
  B.hPutStr (hookInput hook) "\n"
  hFlush (hookInput hook)

-- Read one reply line from the helper's output pipe through the GHC IO manager.
-- The pipe is non-blocking (startOffloadHook); a raw blocking hGetLine would hold
-- this thread's capability while the helper is silent, and the next GC needs every
-- capability to stop, freezing the other clients.  threadWaitRead releases the
-- capability while parked.  (The builder pipe is drained separately by finishOffload.)
--
-- EOF (a 0-byte read) means the helper closed its output before sending a complete
-- reply line: throw, as the C++ readLine (util.cc, "unexpected EOF reading a line")
-- and Substitute.receiveLine ("`guix substitute' died unexpectedly") do.  Returning
-- the partial line ("" when nothing was read) would make requestOffload's replyLine
-- see no "# " prefix, emit "\n" and call receiveLine again, which returns "" again —
-- an endless full-CPU spin flooding the client with newlines when a hook dies or
-- closes fd 4 before replying.  A complete line still ends at its newline.
receiveLine :: Hook -> IO ByteString
receiveLine hook = go []
  where
    fd = hookOutputFd hook
    go acc = do
      byte <- readSomeNonBlocking fd 1
      if B.null byte
        then throwIO (storeError "offload hook closed its output")
        else case C.head byte of
          '\n' -> pure (B.concat (reverse acc))
          _ -> go (byte : acc)

fdNumber :: Fd -> CInt
fdNumber (Fd fd) = fd

-- | Read up to n bytes from a NON-BLOCKING fd through the GHC IO manager.
-- EAGAIN/EWOULDBLOCK (the pipe is momentarily empty) is NOT EOF: wait with
-- threadWaitReadSTM (finally-unregister) and read again, releasing the capability
-- while parked.  EOF is reported by fdRead as an IOException with isEOFError (it
-- does NOT return an empty ByteString), so catch it and return B.empty — the
-- caller decides what EOF means (receiveLine: the hook died; drainFd: done).  Any
-- other error propagates.
readSomeNonBlocking :: Fd -> ByteCount -> IO ByteString
readSomeNonBlocking fd n = go
  where
    go = do
      r <- (Just <$> fdRead fd n) `catch` handle
      case r of
        Just bytes -> pure bytes
        Nothing -> do
          (wait, unregister) <- threadWaitReadSTM fd
          atomically wait `finally` unregister
          go
    handle :: IOException -> IO (Maybe ByteString)
    handle e
      | isEOFError e = pure (Just B.empty)
      | let errno = ioe_errno e
      , errno == Just (case eAGAIN of Errno n -> n)
        || errno == Just (case eWOULDBLOCK of Errno n -> n) = pure Nothing
      | otherwise = throwIO e

closeIgnore :: Handle -> IO ()
closeIgnore handle = hClose handle `catchAny` pure ()

catchAny :: IO a -> IO a -> IO a
catchAny action fallback = catch action (\(_ :: SomeException) -> fallback)
