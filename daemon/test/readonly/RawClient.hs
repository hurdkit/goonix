{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Main where

import Control.Exception (IOException, bracket, try)
import Control.Concurrent (threadDelay)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Word (Word32)
import Network.Socket.ByteString (recv, sendAll)
import Goonix.Store.Hash (sha256)
import Goonix.Store.Base32 (encodeBase16)
import Goonix.Store.Wire
import Network.Socket
import System.Environment (getArgs)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  getArgs >>= \case
    [socketPath, store, state] -> withUnix socketPath (clientMain store state)
    _ -> error "usage: RawClient SOCKET STORE STATE"

clientMain :: FilePath -> FilePath -> Socket -> IO ()
clientMain store state client = do
  sendAll client (encodeInt workerMagic1)
  serverMagic <- readInt client
  version <- readInt client
  putStrLn ("server-magic=" ++ show serverMagic ++ " version=" ++ show version)
  sendAll client (encodeInt 0x164 <> encodeInt 0 <> encodeInt 0)
  expectLast client
  putStrLn "got-startup-last"
  let optionFields =
        [ encodeInt 0, encodeInt 0, encodeInt 1, encodeInt 1
        , encodeInt 0, encodeInt 0, encodeInt 0, encodeInt 1
        , encodeInt 1 ]
  sendAll client (mconcat (encodeInt 19 : optionFields ++ [encodeInt 1, encodeString "build-cores", encodeString "4"]))
  expectLast client
  query store state client 1 [encodeString (C.pack (store ++ "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"))]
  query store state client 23 []
  query store state client 24 []
  query store state client 29 [encodeString "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
  query store state client 29 [encodeString "00000000000000000000000000000000"]
  query store state client 81 []
  query store state client 80 []
  query store state client 1 [encodeString (C.pack (store ++ "/does-not-exist"))]
  query store state client 4 [encodeString (C.pack (store ++ "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"))]
  query store state client 5 [encodeString (C.pack (store ++ "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bar"))]
  query store state client 6 [encodeString (C.pack (store ++ "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"))]
  query store state client 14 []
  query store state client 18 [encodeString (C.pack (store ++ "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"))]
  query store state client 26 [encodeString (C.pack (store ++ "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"))]
  query store state client 26 [encodeString (C.pack (store ++ "/cccccccccccccccccccccccccccccccc-foo.drv"))]
  query store state client 22 [encodeString (C.pack (store ++ "/cccccccccccccccccccccccccccccccc-foo.drv"))]
  query store state client 28 [encodeString (C.pack (store ++ "/cccccccccccccccccccccccccccccccc-foo.drv"))]
  query store state client 31 [encodeStrings (map (C.pack . (store ++)) ["/does-not-exist", "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"])]
  query store state client 33 [encodeString (C.pack (store ++ "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"))]
  query store state client 19 [encodeInt 0, encodeInt 0, encodeInt 1, encodeInt 1, encodeInt 0, encodeInt 0, encodeInt 0, encodeInt 1, encodeInt 1, encodeInt 1, encodeString "substitute-urls", encodeString ""]
  query store state client 81 []
  query store state client 4 [encodeString (C.pack (store ++ "/does-not-exist"))]
  query store state client 1 [encodeString (C.pack (store ++ "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"))]
  query store state client 1 [encodeString (C.pack (store ++ "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo/child"))]

withUnix :: FilePath -> (Socket -> IO a) -> IO a
withUnix path action = bracket (socket AF_UNIX Stream defaultProtocol) close $ \client -> do
  connectRetry client 200
  action client
  where
    connectRetry client 0 = connect client (SockAddrUnix path)
    connectRetry client remaining = do
      result <- try (connect client (SockAddrUnix path)) :: IO (Either IOException ())
      case result of
        Right () -> pure ()
        Left _ -> threadDelay 10000 >> connectRetry client (remaining - 1)

readInt :: Socket -> IO Word32
readInt client = do
  bytes <- readExactly client 8
  either (error . C.unpack) pure (decodeInt bytes)

expectLast :: Socket -> IO ()
expectLast client = do
  value <- readInt client
  if value == stderrLast
    then pure ()
    else if value == stderrError
      then do
        message <- readString client
        status <- readInt client
        error ("server error: " ++ show message ++ " status=" ++ show status)
      else error ("expected STDERR_LAST, got " ++ show value)

awaitLast :: Socket -> IO (Maybe B.ByteString)
awaitLast client = do
  value <- readInt client
  case value of
    _ | value == stderrLast -> pure Nothing
      | value == stderrNext -> readString client >> awaitLast client
      | value == stderrWrite -> readString client >> awaitLast client
      | value == stderrError -> do
          message <- readString client
          status <- readInt client
          pure (Just (message <> encodeInt status))
      | otherwise -> error ("unexpected stderr frame " ++ show value)

query :: FilePath -> FilePath -> Socket -> Word32 -> [B.ByteString] -> IO ()
query store state client code arguments = do
  putStrLn ("query=" ++ show code)
  sendAll client (encodeInt code <> mconcat arguments)
  result <- awaitLast client
  case result of
    Just errorBytes -> do
      let canonical = replaceBytes (C.pack store) "STORE" (replaceBytes (C.pack state) "STATE" errorBytes)
      putStrLn ("error-" ++ show code ++ " length=" ++ show (B.length errorBytes) ++ " sha256=" ++ C.unpack (encodeBase16 (sha256 canonical)))
    Nothing -> do
      reply <- case code of
        1 -> readExactly client 8
        4 -> readString client
        5 -> readStrings client
        6 -> readStrings client
        14 -> readPairs client
        18 -> readString client
        19 -> pure B.empty
        22 -> readStrings client
        28 -> readStrings client
        23 -> readStrings client
        24 -> readStrings client
        26 -> do
          deriver <- readString client
          hash <- readString client
          references <- readStrings client
          registration <- readExactly client 8
          size <- readExactly client 8
          pure (deriver <> hash <> references <> registration <> size)
        29 -> readString client
        31 -> readStrings client
        33 -> readStrings client
        80 -> readStrings client
        81 -> readStrings client
        _ -> error "unknown raw query reply"
      let canonical = replaceBytes (C.pack store) "STORE" (replaceBytes (C.pack state) "STATE" reply)
      putStrLn ("reply-" ++ show code ++ " length=" ++ show (B.length canonical) ++ " sha256=" ++ C.unpack (encodeBase16 (sha256 canonical)))

replaceBytes :: B.ByteString -> B.ByteString -> B.ByteString -> B.ByteString
replaceBytes needle replacement input
  | B.null needle = input
  | otherwise = go input
  where
    go bytes = case B.breakSubstring needle bytes of
      (before, after) | B.null after -> before
      (before, after) -> before <> replacement <> go (B.drop (B.length needle) after)

readExactly :: Socket -> Int -> IO B.ByteString
readExactly client size = go size []
  where
    go 0 chunks = pure (B.concat (reverse chunks))
    go remaining chunks = do
      chunk <- recv client (min remaining 65536)
      if B.null chunk then error "unexpected end-of-file"
        else go (remaining - B.length chunk) (chunk:chunks)

readString :: Socket -> IO B.ByteString
readString client = do
  lengthBytes <- readExactly client 8
  let length' :: Int
      length' = either (const 0) fromIntegral (decodeInt lengthBytes)
      padding = paddingLength length'
  contents <- readExactly client (length' + padding)
  pure (lengthBytes <> contents)

readPairs :: Socket -> IO B.ByteString
readPairs client = do
  countBytes <- readExactly client 8
  let count :: Int
      count = either (const 0) fromIntegral (decodeInt countBytes)
  pairs <- mapM (const ((<>) <$> readString client <*> readString client)) [1 .. count]
  pure (countBytes <> mconcat pairs)

readStrings :: Socket -> IO B.ByteString
readStrings client = do
  countBytes <- readExactly client 8
  let count :: Int
      count = either (const 0) fromIntegral (decodeInt countBytes)
  values <- mapM (const (readString client)) [1 .. count]
  pure (countBytes <> mconcat values)
