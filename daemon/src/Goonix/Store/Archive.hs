{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Archive
  ( exportPath
  , importPaths
  , importPathsFrom
  , rewriteNarPaths
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Word (Word32, Word64)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Goonix.Store.Base32 (encodeBase16)
import Goonix.Store.Hash
import Goonix.Store.Nar
import Goonix.Store.Path (makeFixedOutputPath, makeTextPath, storePathToName, validateStoreName)
import Goonix.Store.ReadOnly
import Goonix.Store.Wire
import Goonix.Store.Writing
import Goonix.Store.Files (deleteTree, restoreNar, deduplicateTree)
import System.Posix.ByteString (RawFilePath)
import System.IO (Handle, hPutStrLn, hFlush)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import System.Posix.Env (getEnv)
import System.Posix.Files (getFileStatus, fileMode)
import Data.Bits ((.&.))

exportMagic :: Word32
exportMagic = 0x4558494e

exportPath :: Store -> ByteString -> Bool -> IO ByteString
exportPath store path sign = do
  _ <- assertStorePath store path
  valid <- isValidPath store path
  unless valid (throwIO (storeError ("path `" ++ C.unpack path ++ "' is not valid")))
  nar <- dumpNar path
  let narHash = hashBytes SHA256 nar
      stored = queryPathHash store path
  storedHash <- stored
  unless (B.null storedHash || storedHash == narHash) (throwIO (storeError "path changed during export"))
  info <- queryPathInfo store path
  let prefix = nar <> encodeInt exportMagic <> encodeString path <> encodeStrings (infoReferences info) <> encodeString (infoDeriver info)
      signedHash = hashBytes SHA256 prefix
  signature <- if sign then signHash signedHash else pure B.empty
  pure (prefix <> encodeInt (if sign then 1 else 0) <> if sign then encodeString signature else B.empty)

importPaths :: Store -> ByteString -> IO [ByteString]
importPaths store input = do
  (paths, rest) <- importPathsFrom store (byteStringSource input)
  unless (B.null rest) (throwIO (storeError "trailing archive bytes"))
  pure paths

importPathsFrom :: Store -> IO ByteString -> IO ([ByteString], ByteString)
importPathsFrom store readMore = do
  state <- newIORef B.empty
  let ensure count = do
        bytes <- readIORef state
        if B.length bytes >= count then pure bytes else do
          more <- readMore
          when (B.null more) (throwIO (storeError "truncated archive"))
          writeIORef state (bytes <> more)
          ensure count
      consume count = do
        bytes <- ensure count
        let (wanted, rest) = B.splitAt count bytes
        writeIORef state rest
        pure wanted
      integer = readInteger consume
      string = readString consume integer
      strings = do
        countBytes <- consume 8
        count <- readWord64 countBytes
        when (count > 64 * 1024 * 1024) (throwIO (storeError "archive string list is too large"))
        mapM (const string) [1 .. count :: Word64]
      loop acc = do
        markerBytes <- consume 8
        n <- case decodeWord64 markerBytes of
          Left message -> throwIO (StoreError message 1)
          Right value -> pure value
        if n == 0 then pure (reverse acc) else if n /= 1
          then throwIO (storeError "input doesn't look like something created by `nix-store --export'")
          else do
            path <- importFromSource store consume integer string strings
            loop (path:acc)
  paths <- loop []
  rest <- readIORef state
  pure (paths, rest)

byteStringSource :: ByteString -> IO ByteString
byteStringSource input = do
  state <- newIORef input
  bytes <- readIORef state
  writeIORef state B.empty
  pure bytes

-- | Rewrite store paths inside a built output, in place, matching the C++
-- daemon's check-mode hash rewriting (build.cc rewritesFromTmp): serialise the
-- output to a NAR, replace each @from@ path with the same-length @to@ path in
-- the NAR bytes, and restore the result.  Used in check mode to turn the
-- redirected (temporary) output paths back into the original paths before the
-- determinism hash is computed, so a builder that embeds $out in its output
-- (e.g. the bootstrap Guile wrapper) compares equal to the original build.
-- Every replacement must preserve length, or the NAR framing would break.
rewriteNarPaths :: RawFilePath -> [(ByteString, ByteString)] -> IO ()
rewriteNarPaths path replacements = do
  mapM_ (\(from, to) -> when (B.length from /= B.length to)
    (throwIO (storeError "check-mode path rewrite must preserve length"))) replacements
  nar <- dumpNar path
  let rewritten = foldl (\bytes (from, to) -> rewriteBytes from to bytes) nar replacements
  if rewritten == nar then pure () else do
    state <- newIORef rewritten
    let consume count = do
          bytes <- readIORef state
          when (B.length bytes < count) (throwIO (storeError "truncated rewritten NAR"))
          let (wanted, rest) = B.splitAt count bytes
          writeIORef state rest
          pure wanted
        integer = readInteger consume
        string = readString consume integer
    (_, tree) <- readNar consume string
    deleteTree path
    restoreNar path tree
  where
    rewriteBytes from to bytes = B.intercalate to (splitOnBytes from bytes)
    splitOnBytes separator input = case B.breakSubstring separator input of
      (before, after) | B.null after -> [before]
                      | otherwise -> before : splitOnBytes separator (B.drop (B.length separator) after)

type Consume = Int -> IO ByteString
type ReadString = IO ByteString

importFromSource :: Store -> Consume -> IO Word32 -> ReadString -> IO [ByteString] -> IO ByteString
importFromSource store consume integer string strings = do
  captured <- newIORef B.empty
  let capture count = do
        bytes <- consume count
        modifyIORef' captured (<> bytes)
        pure bytes
      narInteger = readInteger capture
      narString = readString capture narInteger
  (_, tree) <- readNar capture narString
  nar <- readIORef captured
  magic <- integer
  path <- string
  references <- strings
  deriver <- string
  hasSignature <- integer
  signature <- if hasSignature == 1 then string else pure B.empty
  registerImported store nar tree magic path references deriver signature
  pure path

readInteger :: Consume -> IO Word32
readInteger consume = do
  bytes <- consume 8
  either (\message -> throwIO (StoreError message 1)) pure (decodeInt bytes)

readWord64 :: ByteString -> IO Word64
readWord64 = either (\message -> throwIO (StoreError message 1)) pure . decodeWord64

readString :: Consume -> IO Word32 -> IO ByteString
readString consume integer = do
  size <- fromIntegral <$> integer
  when (size > 64 * 1024 * 1024) (throwIO (storeError "archive string is too large"))
  raw <- consume (size + paddingLength size)
  when (B.any (/= 0) (B.drop size raw)) (throwIO (storeError "non-zero archive string padding"))
  pure (B.take size raw)


readNar :: Consume -> ReadString -> IO (ByteString, Nar)
readNar consume string = do
  header <- string
  when (header /= "nix-archive-1") (throwIO (storeError "invalid NAR header"))
  (node, tree) <- readNode 256
  pure (encodeString header <> node, tree)
  where
    tagged tag = do
      value <- string
      when (value /= tag) (throwIO (storeError ("invalid NAR tag: " ++ C.unpack value)))
      pure (encodeString value)
    readNode depth = do
      when (depth <= 0) (throwIO (storeError "nar directory nesting limit reached"))
      open <- tagged "("
      typeTag <- tagged "type"
      kind <- string
      (body, tree) <- case kind of
        "regular" -> do
          executableTag <- string
          (executableBytes, tag) <- if executableTag == "executable"
            then do
              marker <- string
              when (not (B.null marker)) (throwIO (storeError "non-empty executable marker"))
              next <- string
              pure (encodeString executableTag <> encodeString marker, next)
            else pure (B.empty, executableTag)
          when (tag /= "contents") (throwIO (storeError "invalid NAR contents"))
          lengthBytes <- consume 8
          size <- case decodeWord64 lengthBytes of
            Left message -> throwIO (StoreError message 1)
            Right value -> pure value
          when (size > fromIntegral (maxBound :: Int)) (throwIO (storeError "NAR contents are too large"))
          contents <- consume (fromIntegral size + paddingLength (fromIntegral size))
          close <- tagged ")"
          let value = B.take (fromIntegral size) contents
          pure (encodeString executableTag <> encodeString tag <> lengthBytes <> contents <> close, Regular (not (B.null executableBytes)) value)
        "symlink" -> do
          tag <- tagged "target"
          target <- string
          close <- tagged ")"
          pure (encodeString tag <> encodeString target <> close, Symlink target)
        "directory" -> do
          (entries, children) <- readEntries depth Nothing []
          pure (entries, Directory children)
        _ -> throwIO (storeError "unknown NAR node type")
      pure (open <> typeTag <> encodeString kind <> body, tree)
    readEntries depth previous acc = do
      tag <- string
      if tag == ")" then pure (encodeString tag, reverse acc) else do
        open <- tagged "("
        nameTag <- tagged "name"
        name <- string
        nodeTag <- tagged "node"
        when (tag /= "entry" || B.null name || name == "." || name == ".." || B.any (\b -> b == 0 || b == 47) name)
          (throwIO (storeError "NAR contains invalid file name"))
        when (maybe False (name <=) previous) (throwIO (storeError "NAR directory is not sorted"))
        (childBytes, child) <- readNode (depth - 1)
        close <- tagged ")"
        (rest, children) <- readEntries depth (Just name) ((name, child):acc)
        pure (encodeString tag <> open <> nameTag <> encodeString name <> nodeTag <> childBytes <> close <> rest, children)

validateStorePathName :: ByteString -> Either String ()
validateStorePathName name = case validateStoreName name of
  Right () -> Right ()
  Left _ -> Left ("path name `" ++ C.unpack name ++ "' is not a valid store path")

registerImported :: Store -> ByteString -> Nar -> Word32 -> ByteString -> [ByteString] -> ByteString -> ByteString -> IO ()
registerImported store nar tree magic path references deriver signature = do
  _ <- assertStorePath store path
  either (throwIO . storeError) pure (validateStorePathName (storePathToName (storeDirectory store) path))
  mapM_ (assertStorePath store) references
  unless (B.null deriver) $ void (assertStorePath store deriver)
  when (magic /= exportMagic) (throwIO (storeError "normalized archive cannot be imported; wrong format"))
  let hash = hashBytes SHA256 (nar <> encodeInt exportMagic <> encodeString path <> encodeStrings references <> encodeString deriver)
  authentication <- try $ do
    when (B.null signature) (throwIO (storeError ("imported archive of `" ++ C.unpack path ++ "' lacks a signature")))
    verified <- verifySignature signature
    when (verified /= encodeBase16 hash) (throwIO (storeError "signed hash doesn't match actual contents of imported archive; archive could be corrupt, or someone is trying to import a Trojan horse"))
  case authentication of
    Right () -> pure ()
    Left exception -> do
      unless (B.null deriver && contentAddressed store path nar tree references) $
        throwIO (exception :: SomeException)
  valid <- isValidPath store path
  unless valid $ do
    deleteTree path
    restoreNar path tree
    _ <- canonicaliseAndHash store path
    deduplicateTree (storeDirectory store) path
    narHash <- hashNar path
    registerPath store path narHash (fromIntegral (B.length nar)) references deriver

contentAddressed :: Store -> ByteString -> ByteString -> Nar -> [ByteString] -> Bool
contentAddressed store path narBytes nar references =
  let name = storePathToName (storeDirectory store) path
      recursive = null references && path == makeFixedOutputPath (storeDirectory store) True SHA256 (sha256 narBytes) name
      flat = case nar of
        Regular _ contents ->
          path == makeTextPath (storeDirectory store) name contents references
            || (null references && path == makeFixedOutputPath (storeDirectory store) False SHA256 (sha256 contents) name)
        _ -> False
  in recursive || flat

signHash :: ByteString -> IO ByteString
signHash hash = do
  directory <- maybe "/etc/guix" id <$> getEnv "GUIX_CONFIGURATION_DIRECTORY"
  let key = directory ++ "/signing-key.sec"
      hexHash = encodeBase16 hash
  status <- getFileStatus key
  when (fileMode status .&. 0o077 /= 0) (throwIO (storeError "signing key is accessible to others"))
  authenticate ("sign " ++ show (length key) ++ ":" ++ key ++ " " ++ show (B.length hexHash) ++ ":" ++ C.unpack hexHash)
verifySignature :: ByteString -> IO ByteString
verifySignature signature = authenticate ("verify " ++ show (B.length signature) ++ ":" ++ C.unpack signature)

authenticate :: String -> IO ByteString
authenticate command = do
  program <- maybe "guix" id <$> getEnv "GUIX"
  (input, output, _, process) <- createProcess (proc program ["authenticate"])
    { std_in = CreatePipe, std_out = CreatePipe }
  case (input, output) of
    (Just inHandle, Just outHandle) -> do
      hPutStrLn inHandle command
      hFlush inHandle
      reply <- readReplyHeader outHandle
      let (code, rest) = B.break (== 32) reply
          lenText = B.takeWhile (/= 58) (B.drop 1 rest)
          len = read (C.unpack lenText) :: Int
      payload <- B.hGet outHandle len
      when (code /= "0") (throwIO (storeError (C.unpack payload)))
      _ <- waitForProcess process
      pure payload
    _ -> throwIO (storeError "cannot create authentication pipes")

readReplyHeader :: Handle -> IO ByteString
readReplyHeader handle = go B.empty
  where
    go acc = do
      byte <- B.hGet handle 1
      when (B.null byte) (throwIO (storeError "empty authentication reply"))
      let bytes = acc <> byte
      if byte == ":" then pure bytes else go bytes
