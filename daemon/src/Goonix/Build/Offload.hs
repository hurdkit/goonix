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
  ) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracketOnError, catch, throwIO)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import System.Exit (ExitCode (..))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Goonix.Store.ReadOnly (storeError)
import System.IO (Handle, hClose, hFlush)
import System.Posix.IO.ByteString (createPipe, closeFd, fdToHandle, setFdOption, FdOption (CloseOnExec))
import System.Posix.Process (getProcessStatus, ProcessStatus (Exited, Terminated, Stopped))
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Posix.Types (Fd (..), ProcessID)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)

data HookReply = HookDecline | HookPostpone | HookAccept deriving (Eq, Show)

data Hook = Hook
  { hookInput :: !Handle
  , hookOutput :: !Handle
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
    input <- fdToHandle inputWrite
    output <- fdToHandle outputRead
    builder <- fdToHandle builderRead
    stopped <- newMVar False
    pure (Hook input output builder pid stopped)
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
  _ <- forkFinally (drain (hookOutput hook)) (putMVar agentDrained)
  _ <- forkFinally (drain (hookBuilder hook)) (putMVar builderDrained)
  status <- getProcessStatus True False (hookPid hook)
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

stopHook :: Hook -> IO ()
stopHook hook = do
  stopped <- takeMVar (hookStopped hook)
  unless stopped $ do
    closeIgnore (hookInput hook)
    closeIgnore (hookOutput hook)
    closeIgnore (hookBuilder hook)
    -- Agent::~Agent uses a separate process group and SIGKILL.
    signalProcessGroup sigKILL (hookPid hook) `catchAny` pure ()
    _ <- getProcessStatus True False (hookPid hook) `catchAny` pure Nothing
    pure ()
  putMVar (hookStopped hook) True

sendLine :: Hook -> ByteString -> IO ()
sendLine hook line = do
  B.hPutStr (hookInput hook) line
  B.hPutStr (hookInput hook) "\n"
  hFlush (hookInput hook)

receiveLine :: Hook -> IO ByteString
receiveLine hook = C.hGetLine (hookOutput hook)

fdNumber :: Fd -> CInt
fdNumber (Fd fd) = fd

closeIgnore :: Handle -> IO ()
closeIgnore handle = hClose handle `catchAny` pure ()

catchAny :: IO a -> IO a -> IO a
catchAny action fallback = catch action (\(_ :: SomeException) -> fallback)
