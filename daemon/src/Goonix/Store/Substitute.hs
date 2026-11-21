{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Substitute
  ( SubstitutableInfo
  , substitutablePaths
  , substitutableInfo
  , substitutableInfos
  , substitutePath
  ) where

import Control.Exception (SomeException, bracket, catch, throwIO)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Goonix.Store.ReadOnly (StoreError (..), storeError)
import Goonix.Store.Config (ServerConfig (..))
import Goonix.Store.Settings
import System.IO (Handle, hClose, hFlush)
import System.Posix.IO.ByteString (createPipe, closeFd, fdToHandle, setFdOption, FdOption (CloseOnExec))
import System.Posix.Process (getProcessStatus)
import System.Posix.Signals (sigTERM, signalProcess)
import System.Posix.Types (CPid (..), Fd (..), ProcessID)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)

type SubstitutableInfo = (ByteString, ByteString, [ByteString], Word64, Word64)

data Agent = Agent Handle Handle Handle ProcessID

foreign import ccall unsafe "goonix_spawn_helper"
  c_spawn_helper :: CString -> CString -> CInt -> CInt -> CInt -> CString -> Ptr CInt -> IO CInt

withAgent :: ServerConfig -> Settings -> ByteString -> (Agent -> IO a) -> IO a
withAgent config settings argument action = bracket start stop action
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
      pure (Agent input output logOutput pid)
    stop (Agent input output logOutput pid) = do
      hClose input `catchAny` pure ()
      signalProcess sigTERM pid `catchAny` pure ()
      _ <- getProcessStatus True False pid
      hClose output `catchAny` pure ()
      hClose logOutput `catchAny` pure ()
      pure ()

fdNumber :: Fd -> CInt
fdNumber (Fd value) = value

packSettings :: Settings -> ByteString
packSettings settings = B.concat [key <> "=" <> value <> "\n" | (key, value) <- Map.toAscList (values settings)]

substitutablePaths :: ServerConfig -> Settings -> [ByteString] -> IO [ByteString]
substitutablePaths config settings paths
  | null paths = pure []
  | otherwise = withAgent config settings "--query" $ \agent -> do
      sendLine agent ("have" <> foldMap (" " <>) paths <> " ")
      readPaths agent []

substitutableInfo :: ServerConfig -> Settings -> ByteString -> IO (Maybe (ByteString, [ByteString], Word64, Word64))
substitutableInfo config settings path = do
  infos <- substitutableInfos config settings [path]
  pure $ case infos of
    [(_, deriver, references, downloadSize, narSize)] -> Just (deriver, references, downloadSize, narSize)
    _ -> Nothing

substitutableInfos :: ServerConfig -> Settings -> [ByteString] -> IO [SubstitutableInfo]
substitutableInfos config settings paths
  | null paths = pure []
  | otherwise = withAgent config settings "--query" $ \agent -> do
      sendLine agent ("info" <> foldMap (" " <>) paths <> " ")
      readInfos agent []

substitutePath :: ServerConfig -> Settings -> ByteString -> ByteString -> IO (Either ByteString (ByteString, Word64))
substitutePath config settings path destination = withAgent config settings "--substitute" $ \agent -> do
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
sendLine (Agent input _ _ _) line = do
  B.hPutStr input line
  B.hPutStr input "\n"
  hFlush input

receiveLine :: Agent -> IO ByteString
receiveLine (Agent _ output _ _) = C.hGetLine output

readCount :: Agent -> IO Int
readCount agent = do
  line <- receiveLine agent
  case reads (C.unpack line) of
    [(number, "")] -> pure number
    _ -> throwIO (storeError ("integer expected from stream: " ++ C.unpack line))

catchAny :: IO a -> IO a -> IO a
catchAny action fallback = catch action (\(_ :: SomeException) -> fallback)
