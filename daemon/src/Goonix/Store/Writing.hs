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

import Control.Exception (finally, throwIO)
import Control.Monad (forM_, unless, when, foldM)
import Data.Char (toUpper)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Int
import Data.Word (Word64)
import Goonix.Store.Base32 (encodeBase16, encodeBase32)
import Goonix.Store.Ca (goonixAddressed, resolvedDerivation)
import Goonix.Store.CaBuild (checkGoonixDerivationOutputs, checkInputAddressedPolicy)
import Goonix.Store.Database
import Goonix.Store.Derivation (parseDerivation, outputs, outputPath, outputHash, parseHashInfo, environment, derivationOutputPaths, hashDerivationModulo, blankOutputPaths, inputDrvs, Derivation)
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
        -- The non-recursive path drops the NAR's executable bit: the C++
        -- handler collects the contents with RetrieveRegularNARSink, which
        -- does not override isExecutable() (a no-op in ParseSink), writes
        -- them with writeFile (0666 & ~umask) and canonicalises to 0444.
        -- Only the RECURSIVE path restores the NAR, and restorePath honours
        -- the bit.  Keeping it here made the stored mode 0555 and gave a
        -- different narHash/narSize for the same input.
        else writeBytes destination contents
      _ <- canonicaliseAndHash store destination
      deduplicateTree (storeDirectory store) destination
      narHash <- if recursive && algorithm == SHA256 then pure (Hash SHA256 digest) else hashNar destination
      narSize <- if recursive then pure (fromIntegral (B.length dump)) else narSizeOf destination
      registerPath store destination narHash narSize [] ""
      pure destination
  where
    narSizeOf path = narSize path

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
      (hash, size) <- hashNarSize destination
      registerPath store destination hash size references ""
      pure destination

canonicaliseAndHash :: Store -> ByteString -> IO (Hash, Word64)
canonicaliseAndHash store path = do
  let root = storeDirectory store
  status <- getSymbolicLinkStatus root
  let mode = fileMode status
  setFileMode root 0o755
  -- One streaming pass computes the hash and the NAR length together (C++
  -- hashPath = HashSink over dumpPath).  Never dumpNar the whole tree just to
  -- learn its length: that pins two copies of the output in the heap.
  (hash, size) <- (canonicaliseTree path >> hashNarSize path) `finally` setFileMode root mode
  pure (hash, size)

registerPath :: Store -> ByteString -> Hash -> Word64 -> [ByteString] -> ByteString -> IO ()
registerPath store path (Hash algorithm digest) size references deriver = do
  when (algorithm /= SHA256) (throwIO (storeError "store registration requires SHA-256"))
  retryBusy $ withTransaction (database store) $ do
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
          -- goonix: address-specific output validation (C++ checkGoonixBatchRegistration,
          -- local-store.cc:996, run after addValidPath with checkOutputs=false): a CA
          -- derivation's output paths must match their placeholder/token/fixed identity
          -- and its environment the logical token; a malformed CA derivation is refused
          -- and the registration rolled back.
          if (goonixAddressed (Map.lookup "goonixAddressing" (environment derivation))
                || resolvedDerivation (Map.lookup "goonixResolved" (environment derivation)))
            then either (throwIO . storeError) pure (checkGoonixDerivationOutputs (storeDirectory store) path derivation)
            -- goonix: C++ registerValidPaths (local-store.cc:1001) runs
            -- checkInputAddressedPolicy for a non-CA derivation at registration,
            -- so an input-addressed derivation with a CA input is refused before
            -- any build (the ca-sharing mixed-policy case).
            else do
              -- goonix: C++ registerValidPaths (local-store.cc:1000) runs
              -- checkDerivationOutputs BEFORE the addressing policy for every
              -- non-CA derivation.  Recompute each output path from the
              -- derivation itself: without this an unmarked forged derivation
              -- could name ANY store path and have it registered as valid
              -- (tests/store-path-check.scm, "an unmarked derivation with a
              -- chosen output path is refused", which the HS daemon used to
              -- answer 'poisoned).
              checkDerivationOutputs store path derivation
              -- goonix: C++ registerValidPaths (local-store.cc:1001) runs
              -- checkInputAddressedPolicy for a non-CA derivation at registration,
              -- so an input-addressed derivation with a CA input is refused before
              -- any build (the ca-sharing mixed-policy case).
              checkInputAddressedPolicy derivation $ \input -> do
                inputValid <- isValidPath store input
                if not inputValid then pure Nothing else do
                  inputBytes <- B.readFile (C.unpack input)
                  pure (either (const Nothing) Just (parseDerivation inputBytes))
          forM_ (Map.elems (outputs derivation)) $ \output ->
            unless (B.null (outputHash output)) $ do
              (_, algorithm, digest) <- either (throwIO . storeError) pure (parseHashInfo output)
              when (B.length digest /= digestLength algorithm) $
                throwIO (storeError ("invalid " ++ C.unpack (C.map toUpper (algorithmName algorithm)) ++ " hash"))
          forM_ (Map.toList (outputs derivation)) $ \(name, output) ->
            execute (database store) "insert or replace into DerivationOutputs(drv,id,path) values (?,?,?);"
              [Integer identifier, Bytes name, Bytes (outputPath output)]
      _ -> throwIO (storeError "registered path has no database id")

-- | C++ LocalStore::checkDerivationOutputs (nix/libstore/local-store.cc:468-505).
-- Every output path of a NON-CA derivation is a function of the derivation, not
-- of its author: a fixed output is makeFixedOutputPath over its declared hash,
-- anything else is makeOutputPath over hashDerivationModulo of the derivation
-- with its output paths blanked (local-store.cc:489-498).  C++ also requires
-- the environment entry for each output to name that same path
-- (local-store.cc:499-501).  Registration throws on any mismatch, and its
-- transaction rolls back.
checkDerivationOutputs :: Store -> ByteString -> Derivation -> IO ()
checkDerivationOutputs store drvPath drv = do
  -- C++ hashDerivationModulo (nix/libstore/derivations.cc:259-266) replaces each
  -- input derivation path by that derivation's OWN modulo hash, reading it from
  -- the store and recursing.  Do those reads in IO first, so the pure function
  -- gets a lookup table rather than an IO callback it cannot run.
  hashes <- foldM collect Map.empty (Map.keys (inputDrvs drv))
  expected <- either (throwIO . storeError) pure
    (derivationOutputPaths (storeDirectory store) drvPath drv (lookupHash hashes))
  forM_ (Map.toList (outputs drv)) $ \(name, output) -> do
    let wanted = Map.findWithDefault "" name expected
        actual = outputPath output
        envValue = Map.findWithDefault "" name (environment drv)
    when (actual /= wanted || envValue /= wanted) $
      throwIO (storeError ("derivation `" ++ C.unpack drvPath ++ "' has incorrect output `"
        ++ C.unpack actual ++ "', should be `" ++ C.unpack wanted ++ "'"))
  where
    lookupHash hashes path = Map.findWithDefault
      (Left ("cannot read input derivation `" ++ C.unpack path ++ "'")) path hashes
    -- C++ memoises in drvHashes (derivations.cc:260-266) and so visits each
    -- derivation once.  Without that memo the accumulator is dropped at every
    -- level and a diamond-shaped input graph is re-read and re-hashed
    -- exponentially; tests/gexp.scm and tests/graph.scm hung on it.
    collect acc path
      | Map.member path acc = pure acc
      | otherwise = do
          present <- isValidPath store path
          if not present
            then pure (Map.insert path
              (Left ("input derivation `" ++ C.unpack path ++ "' is not valid")) acc)
            else do
              bytes <- B.readFile (C.unpack path)
              case parseDerivation bytes of
                Left message -> pure (Map.insert path (Left message) acc)
                Right input -> do
                  nested <- foldM collect acc (Map.keys (inputDrvs input))
                  -- Do NOT blank the input here: derivationOutputPaths already
                  -- blanked THIS derivation's outputs, and hashDerivationModulo
                  -- (derivations.cc:259-266) hashes each input derivation as it
                  -- is stored.  Blanking again hashes a different derivation.
                  pure (Map.insert path
                    (hashDerivationModulo input (lookupHash nested)) nested)

addIndirectRoot :: Store -> ByteString -> IO ()
addIndirectRoot store link = do
  let state = storeStateDirectory store
      digest = hashDigest (Hash SHA1 (sha1 link))
      root = state <> "/gcroots/auto/" <> encodeBase32Short digest
  makeSymlinkAtomic link root

encodeBase32Short :: ByteString -> ByteString
encodeBase32Short = encodeBase32 . compressHash 20

epochTimeSeconds :: IO Data.Int.Int64
epochTimeSeconds = floor <$> getPOSIXTime

registerFailedPath :: Store -> ByteString -> IO ()
registerFailedPath store path = do
  now <- epochTimeSeconds
  retryBusy $ execute (database store) "insert or replace into FailedPaths(path,time) values (?,?);"
    [Bytes path, Integer now]

clearFailedPaths :: Store -> [ByteString] -> IO ()
clearFailedPaths store paths = retryBusy $ withTransaction (database store) $
  forM_ paths $ \path ->
    execute (database store) "delete from FailedPaths where path = ?;" [Bytes path]
