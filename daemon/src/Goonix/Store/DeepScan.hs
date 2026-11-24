{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

-- | goonix: run the deep CA decoder in a separate, unprivileged process
-- (HS-11, C++ nix/libstore/deep-scan.cc).  When goonix-deep-scan is set, the
-- configured libexec helper (goonix-ca-scan) is launched over the build tree
-- with every output self token; a found token or any helper failure is a build
-- error, and only the helper's explicit clean status permits finalisation.
module Goonix.Store.DeepScan
  ( checkDeepOutput
  , deepScanHelperPath
  , readDiagnostic
  ) where

import Control.Exception (SomeException, bracket, catch, evaluate, throwIO, try)
import Control.Monad (unless, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import Foreign.Marshal.Array (withArray0)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import Goonix.Store.Settings (Settings, setting, settingBool, settingInt)
import qualified Goonix.Config as Config
import System.Posix.ByteString (RawFilePath)
import System.Posix.Files (fileExist, isRegularFile, getFileStatus, fileAccess)
import System.Posix.IO.ByteString (createPipe, fdToHandle, closeFd)
import System.Posix.Process (getProcessStatus, ProcessStatus (..))
import System.Posix.Signals (sigKILL, signalProcess)
import System.Posix.Types (CPid (..), Fd (..))
import System.Posix.Env.ByteString (getEnv)
import System.Exit (ExitCode (..))
import System.IO (hGetContents, hClose, Handle)
import System.Timeout (timeout)

foreign import ccall unsafe "goonix_spawn_deep_scan"
  c_spawn_deep_scan :: CString -> CString -> Ptr CString -> CInt -> CInt
    -> CUInt -> CUInt -> Ptr CInt -> IO CInt

-- | The build-tree override or the make-expanded installed helper
-- (C++ deepScanHelperPath).  GOONIX_DEEP_SCAN_HELPER (set by pre-inst-env to the
-- build-tree goonix-ca-scan) wins over the goonix-deep-scan-helper setting,
-- which wins over the installed libexec default.
deepScanHelperPath :: Settings -> IO RawFilePath
deepScanHelperPath settings = do
  override <- getEnv "GOONIX_DEEP_SCAN_HELPER"
  let configured = setting "goonix-deep-scan-helper" "" settings
      chosen = case override of
        Just value | not (B.null value) -> value
        _ | not (B.null configured) -> configured
        _ -> C.pack (Config.libexecDirectory ++ "/goonix-ca-scan")
  pure chosen

-- | C++ checkDeepOutput: a no-op unless goonix-deep-scan is set; otherwise run
-- the helper and, on any failure, run the cleanup before rethrowing.
checkDeepOutput :: Settings -> RawFilePath -> [B.ByteString] -> Maybe (CUInt, CUInt) -> IO () -> IO ()
checkDeepOutput settings tree tokens buildUser cleanup
  | not (settingBool "goonix-deep-scan" False settings) = pure ()
  | otherwise = do
      result <- try (runDeepScanHelper settings tree tokens buildUser)
      case result of
        Left (exception :: SomeException) -> do
          _ <- try cleanup :: IO (Either SomeException ())
          throwIO exception
        Right () -> cleanup

runDeepScanHelper :: Settings -> RawFilePath -> [B.ByteString] -> Maybe (CUInt, CUInt) -> IO ()
runDeepScanHelper settings tree tokens buildUser = do
  helper <- deepScanHelperPath settings
  available <- helperAvailable helper
  unless available $
    ioError (userError ("deep CA scan helper is unavailable: `" ++ C.unpack helper ++ "'"))
  let (buildUid, buildGid) = case buildUser of
        Just (uid, gid) -> (uid, gid)
        Nothing -> (maxBound, maxBound)
      timeoutSeconds = settingInt "goonix-deep-scan-timeout" 3600 settings
  (readFd, writeFd) <- createPipe
  -- The child inherits writeFd (dup2 to stdout/stderr); the parent closes its
  -- copy right after the spawn so EOF arrives when the child exits.
  bracket (fdToHandle readFd) hClose $ \readHandle -> do
    pid <- spawn helper tree tokens writeFd buildUid buildGid
    closeFd writeFd
    diagnostic <- readDiagnostic readHandle timeoutSeconds pid
    status <- waitFor pid
    case status of
      Exited ExitSuccess -> pure ()
      Exited (ExitFailure 1) -> throwIO (userError (foundMessage diagnostic))
      Exited (ExitFailure 127) -> ioError (userError ("deep CA scan helper could not be executed: `" ++ C.unpack helper ++ "'"))
      Exited (ExitFailure code) -> ioError (userError ("deep CA scan helper failed (status " ++ show code ++ "): " ++ diagnostic))
      _ -> ioError (userError ("deep CA scan helper crashed: " ++ show status))

helperAvailable :: RawFilePath -> IO Bool
helperAvailable helper = do
  let path = C.unpack helper
  exists <- fileExist path
  if not exists then pure False else do
    status <- getFileStatus path
    executable <- fileAccess path False False True
    pure (isRegularFile status && executable)

spawn :: RawFilePath -> RawFilePath -> [B.ByteString] -> Fd -> CUInt -> CUInt -> IO CPid
spawn helper tree tokens (Fd writeFd) buildUid buildGid =
  B.useAsCString helper $ \helper' ->
    B.useAsCString tree $ \tree' ->
      withCStringArray tokens $ \tokens' ->
        alloca $ \pidPointer -> do
          result <- c_spawn_deep_scan helper' tree' tokens' (fromIntegral (length tokens))
                      writeFd buildUid buildGid pidPointer
          if result < 0
            then ioError (userError "cannot spawn deep CA scan helper")
            else fromIntegral <$> peek pidPointer

withCStringArray :: [B.ByteString] -> (Ptr CString -> IO a) -> IO a
withCStringArray strings action = go strings []
  where
    go [] accumulated = withArray0 nullPtr (reverse accumulated) action
    go (value:rest) accumulated = B.useAsCString value $ \pointer -> go rest (pointer:accumulated)

-- | Read the helper's diagnostic (bounded to 64 KiB) until EOF, killing the
-- child if it exceeds its time limit (C++ polls with a deadline).
readDiagnostic :: Handle -> Int -> CPid -> IO String
readDiagnostic handle timeoutSeconds pid = do
  -- hGetContents is LAZY: it returns a thunk immediately without blocking, so
  -- wrapping only hGetContents in `timeout` would never fire (the thunk is
  -- produced instantly) and the real blocking read would happen later, outside
  -- any deadline.  Force the bounded string INSIDE the timeout so the deadline
  -- actually bounds the read: a helper that keeps the pipe open and never exits
  -- is killed when the limit expires, as C++ does with its poll deadline.
  result <- timeout (timeoutSeconds * 1000000) $ do
    contents <- hGetContents handle
    let bounded = take 65536 contents
    _ <- evaluate (length bounded)
    pure bounded
  case result of
    Nothing -> do
      _ <- try (signalProcess sigKILL pid) :: IO (Either SomeException ())
      ioError (userError ("deep CA scan helper exceeded its " ++ show timeoutSeconds ++ " second limit"))
    Just bounded -> pure bounded

waitFor :: CPid -> IO ProcessStatus
waitFor pid = do
  status <- getProcessStatus True False pid
  case status of
    Just value -> pure value
    Nothing -> waitFor pid

-- | C++ exit-1 diagnostic: kind\toffset\tfile.  kind is placeholder or
-- self-token; the message names the decompressed file and byte offset.
foundMessage :: String -> String
foundMessage diagnostic =
  let (kind, rest1) = break (== '\t') diagnostic
      rest1' = drop 1 rest1
      (offset, rest2) = break (== '\t') rest1'
      file = trimNewlines (drop 1 rest2)
      description = if kind == "placeholder" then "placeholder" else "self token"
  in if null rest1 || null rest2 || (kind /= "placeholder" && kind /= "self-token")
       then "deep CA scan helper returned malformed found data: " ++ diagnostic
       else "unresolved goonix " ++ description ++ " in decompressed `" ++ file ++ "' at byte " ++ offset
  where
    trimNewlines = reverse . dropWhile (\c -> c == '\n' || c == '\r') . reverse