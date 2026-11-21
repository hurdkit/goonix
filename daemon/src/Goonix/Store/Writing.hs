{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Writing
  ( addNarToStore
  , addTextToStore
  , registerPath
  , addIndirectRoot
  , canonicaliseAndHash
  , registerFailedPath
  , clearFailedPaths
  ) where

import Control.Exception (finally, throwIO, try)
import Control.Monad (forM_, unless, when)
import Control.Concurrent (threadDelay)
import Data.Char (toUpper)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Int
import Data.Word (Word64)
import Goonix.Store.Base32 (encodeBase16, encodeBase32)
import Goonix.Store.Database
import Goonix.Store.Derivation (parseDerivation, outputs, outputPath, outputHash, parseHashInfo)
import Goonix.Store.Files
import Goonix.Store.Hash
import Goonix.Store.Nar
import Goonix.Store.Path
import Goonix.Store.ReadOnly
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Posix.Files.ByteString (setFileMode, getSymbolicLinkStatus, fileMode)
import System.Posix.Types (Fd)

addNarToStore :: Fd -> Store -> ByteString -> Bool -> HashAlgorithm -> ByteString -> IO ByteString
addNarToStore rootFd store name recursive algorithm dump = do
  parsed <- either (throwIO . storeError) pure (decodeNar dump)
  contents <- if recursive then pure dump else case parsed of
    Regular _ bytes -> pure bytes
    _ -> throwIO (storeError "regular file expected")
  let digest = hashBytes algorithm contents
      destination = makeFixedOutputPath (storeDirectory store) recursive algorithm digest name
  appendTempRoot rootFd destination
  valid <- isValidPath store destination
  if valid then pure destination else withPathLock destination $ do
    stillValid <- isValidPath store destination
    if stillValid then pure destination else do
      deleteTree destination
      if recursive
        then either (throwIO . storeError) (restoreNar destination) (decodeNar dump)
        else do
          writeBytes destination contents
          case parsed of
            Regular True _ -> setFileMode destination 0o755
            _ -> pure ()
      _ <- canonicaliseAndHash store destination
      deduplicateTree (storeDirectory store) destination
      narHash <- if recursive && algorithm == SHA256 then pure (Hash SHA256 digest) else hashNar destination
      narSize <- if recursive then pure (fromIntegral (B.length dump)) else narSizeOf destination
      registerPath store destination narHash narSize [] ""
      pure destination
  where
    narSizeOf path = fromIntegral . B.length <$> dumpNar path

addTextToStore :: Fd -> Store -> ByteString -> ByteString -> [ByteString] -> IO ByteString
addTextToStore rootFd store name contents references = do
  -- C++ checkStoreName runs inside makeStorePath (store-api.cc), which
  -- computeStorePathForText calls, so an invalid name is rejected here with
  -- "invalid character ..." before any path is computed or written.
  either (throwIO . storeError) pure (validateStoreName name)
  mapM_ (assertStorePath store) references
  let destination = makeTextPath (storeDirectory store) name contents references
  appendTempRoot rootFd destination
  valid <- isValidPath store destination
  if valid then pure destination else withPathLock destination $ do
    stillValid <- isValidPath store destination
    if stillValid then pure destination else do
      deleteTree destination
      writeBytes destination contents
      _ <- canonicaliseAndHash store destination
      deduplicateTree (storeDirectory store) destination
      hash <- hashNar destination
      size <- fromIntegral . B.length <$> dumpNar destination
      registerPath store destination hash size references ""
      pure destination

canonicaliseAndHash :: Store -> ByteString -> IO (Hash, Word64)
canonicaliseAndHash store path = do
  let root = storeDirectory store
  status <- getSymbolicLinkStatus root
  let mode = fileMode status
  setFileMode root 0o755
  hash <- (canonicaliseTree path >> hashNar path) `finally` setFileMode root mode
  size <- fromIntegral . B.length <$> dumpNar path
  pure (hash, size)

registerPath :: Store -> ByteString -> Hash -> Word64 -> [ByteString] -> ByteString -> IO ()
registerPath store path (Hash algorithm digest) size references deriver = do
  when (algorithm /= SHA256) (throwIO (storeError "store registration requires SHA-256"))
  retryRegistration $ withTransaction (database store) $ do
    existing <- queryValues (database store) "select id from ValidPaths where path = ?;" [Bytes path]
    case existing of
      [] -> do
        now <- epochTimeSeconds
        execute (database store)
          "insert into ValidPaths(path,hash,registrationTime,deriver,narSize) values (?,?,?,?,?);"
          [Bytes path, Bytes ("sha256:" <> encodeBase16 digest), Integer now,
           if B.null deriver then Null else Bytes deriver,
           if size == 0 then Null else Integer (fromIntegral size)]
      _ -> execute (database store)
        "update ValidPaths set narSize=?, hash=? where path=?;"
        [if size == 0 then Null else Integer (fromIntegral size), Bytes ("sha256:" <> encodeBase16 digest), Bytes path]
    rows <- queryValues (database store) "select id from ValidPaths where path = ?;" [Bytes path]
    case rows of
      [[Integer identifier]] -> do
        forM_ references $ \reference -> do
          referenceRows <- queryValues (database store) "select id from ValidPaths where path = ?;" [Bytes reference]
          case referenceRows of
            [[Integer referenceId]] -> execute (database store) "insert or replace into Refs(referrer,reference) values (?,?);"
              [Integer identifier, Integer referenceId]
            _ -> throwIO (storeError ("path `" ++ C.unpack reference ++ "' is not valid"))
        when (B.isSuffixOf ".drv" path) $ do
          bytes <- B.readFile (C.unpack path)
          derivation <- either (throwIO . storeError) pure (parseDerivation bytes)
          forM_ (Map.elems (outputs derivation)) $ \output ->
            unless (B.null (outputHash output)) $ do
              (_, algorithm, digest) <- either (throwIO . storeError) pure (parseHashInfo output)
              when (B.length digest /= digestLength algorithm) $
                throwIO (storeError ("invalid " ++ C.unpack (C.map toUpper (algorithmName algorithm)) ++ " hash"))
          forM_ (Map.toList (outputs derivation)) $ \(name, output) ->
            execute (database store) "insert or replace into DerivationOutputs(drv,id,path) values (?,?,?);"
              [Integer identifier, Bytes name, Bytes (outputPath output)]
      _ -> throwIO (storeError "registered path has no database id")

retryRegistration :: IO a -> IO a
retryRegistration action = go (0 :: Int)
  where
    go attempt = do
      result <- try action
      case result of
        Right value -> pure value
        Left (exception :: DatabaseBusy)
          | attempt < 200 -> threadDelay (1000 + attempt * 100) >> go (attempt + 1)
          | otherwise -> throwIO exception

addIndirectRoot :: Store -> ByteString -> IO ()
addIndirectRoot store link = do
  state <- maybe (throwIO (storeError "no state directory")) pure (storeStateDirectory store)
  let digest = hashDigest (Hash SHA1 (sha1 link))
      root = state <> "/gcroots/auto/" <> encodeBase32Short digest
  makeSymlinkAtomic link root

encodeBase32Short :: ByteString -> ByteString
encodeBase32Short = encodeBase32 . compressHash 20

epochTimeSeconds :: IO Data.Int.Int64
epochTimeSeconds = floor <$> getPOSIXTime

registerFailedPath :: Store -> ByteString -> IO ()
registerFailedPath store path = do
  now <- epochTimeSeconds
  execute (database store) "insert or replace into FailedPaths(path,time) values (?,?);"
    [Bytes path, Integer now]

clearFailedPaths :: Store -> [ByteString] -> IO ()
clearFailedPaths store paths = withTransaction (database store) $
  forM_ paths $ \path ->
    execute (database store) "delete from FailedPaths where path = ?;" [Bytes path]
