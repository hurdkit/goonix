{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | goonix CA store operations (HS-11): the records table wired to the store,
-- realised-output selection, resolved-derivation writing, signed build facts,
-- and the read-only graph query.  Ported from nix/libstore/local-store-ca.cc.
module Goonix.Store.CaStore
  ( initCaRecords
  , realisedOutputPath
  , selectGoonixOutput
  , selectGoonixOutputs
  , writeResolvedDerivation
  , resolvedDerivationPath
  , recordBuild
  , recordGoonixOutput
  , queryGoonixBuildGraph
  , goonixRecordFields
  , resolvedHashOf
  ) where

import Control.Monad (foldM, forM, forM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Goonix.Store.Archive (signHash)
import Goonix.Store.Ca (assertNotReserved, goonixAddressed)
import Goonix.Store.CaBuild (resolveDerivation, checkResolvedDerivation, isStorePathStrict)
import Goonix.Store.Database
import Goonix.Store.Derivation
import Goonix.Store.Hash (Hash (..), HashAlgorithm (..), sha256)
import Goonix.Store.Path (storePathToName)
import Goonix.Store.ReadOnly
import Goonix.Store.Records
import Goonix.Store.Writing (addTextToStore)
import System.Posix.Types (Fd)

-- | Create the records tables if absent (C++ initialiseGoonixRecords).
initCaRecords :: Store -> IO ()
initCaRecords store = initialiseRecords (database store)

-- | The hex SHA-256 of a derivation's canonical bytes (C++ resolvedHash).
resolvedHashOf :: Derivation -> ByteString
resolvedHashOf drv = encodeBase16 (sha256 (writeDerivation drv))
  where
    encodeBase16 = B.concatMap (\w -> B.pack [hexChar (w `div` 16), hexChar (w `mod` 16)])
    hexChar n = if n < 10 then 48 + n else 87 + n

readDerivation :: ByteString -> IO Derivation
readDerivation path = do
  bytes <- B.readFile (C.unpack path)
  either (ioError . userError) pure (parseDerivation bytes)

-- | C++ selectGoonixOutput: keep a valid local choice; else the preferred path
-- if valid; else the first valid fact; else nothing (a stale choice stays).
selectGoonixOutput :: Store -> ByteString -> ByteString -> ByteString -> ByteString -> Bool -> IO ByteString
selectGoonixOutput store unresolved output resolvedHash preferred adopt = do
  current <- chosenOutput (database store) unresolved output
  currentValid <- if B.null current then pure False else isValidPath store current
  records <- queryRecords (database store) resolvedHash output
  if adopt && not (B.null preferred)
    then do
      preferredValid <- isValidPath store preferred
      if preferredValid
        then do
          rechooseOutput (database store) unresolved output preferred
          pure preferred
        else keepOrPick current currentValid records
    else keepOrPick current currentValid records
  where
    keepOrPick current currentValid records
      | currentValid = pure current
      | not (B.null preferred) = do
          preferredValid <- isValidPath store preferred
          if preferredValid
            then rechooseOutput (database store) unresolved output preferred >> pure preferred
            else firstValid records
      | otherwise = firstValid records
    firstValid [] = pure B.empty
    firstValid (record:rest) = do
      valid <- isValidPath store (recordPath record)
      if valid
        then rechooseOutput (database store) unresolved output (recordPath record) >> pure (recordPath record)
        else firstValid rest

-- | C++ selectGoonixOutputs: select each output's realised path into the drv.
selectGoonixOutputs :: Store -> ByteString -> Derivation -> IO Derivation
selectGoonixOutputs store originalPath drv = do
  let resolvedHash = resolvedHashOf drv
  outputs' <- forM (Map.toList (outputs drv)) $ \(output, out) -> do
    selected <- selectGoonixOutput store originalPath output resolvedHash B.empty False
    pure (output, if B.null selected then out else out { outputPath = selected })
  pure drv { outputs = Map.fromList outputs' }

-- | C++ realisedOutputPath: fixed/input outputs name themselves; a CA output
-- is its valid choice, else re-resolved against this machine's choices and the
-- permanent facts.
realisedOutputPath :: Store -> ByteString -> Derivation -> ByteString -> IO ByteString
realisedOutputPath store drvPath drv output =
  case Map.lookup output (outputs drv) of
    Nothing -> ioError (userError ("derivation has no output `" ++ C.unpack output ++ "'"))
    Just out ->
      if not (B.null (outputHash out)) || not (goonixAddressed (Map.lookup "goonixAddressing" (environment drv)))
        then pure (outputPath out)
        else do
          chosen <- chosenOutput (database store) drvPath output
          chosenValid <- if B.null chosen then pure False else isValidPath store chosen
          if chosenValid
            then pure chosen
            else do
              resolved <- resolveDerivation (storeDirectory store) drvPath drv (realisedOutputPath store)
              let hash = resolvedHashOf resolved
              selected <- selectGoonixOutput store drvPath output hash B.empty False
              when (B.null selected) $
                ioError (userError ("derivation output `" ++ C.unpack output ++ "' of `"
                  ++ C.unpack drvPath ++ "' is not realised"))
              pure selected

-- | C++ resolvedDerivationPath / writeResolvedDerivation: the resolved
-- derivation is stored as text named after the original (minus .drv), with its
-- input sources as references.  addTextToStore appends the .drv suffix itself.
writeResolvedDerivation :: Fd -> Store -> ByteString -> Derivation -> IO ByteString
writeResolvedDerivation rootFd store originalPath resolved = do
  either (ioError . userError) pure (checkResolvedDerivation (storeDirectory store) resolved)
  resolvedDerivationPath rootFd store originalPath resolved

resolvedDerivationPath :: Fd -> Store -> ByteString -> Derivation -> IO ByteString
resolvedDerivationPath rootFd store originalPath resolved = do
  let name0 = storePathToName (storeDirectory store) originalPath
      name = if ".drv" `B.isSuffixOf` name0 then B.dropEnd 4 name0 else name0
      references = Set.toList (inputSrcs resolved)
  addTextToStore rootFd store (name <> ".drv") (writeDerivation resolved) references

-- | C++ recordBuild: a signed permanent fact.  The resolved hash is recomputed
-- from the stored resolved derivation, never client-supplied.
recordBuild :: Store -> ByteString -> ByteString -> ByteString -> ByteString -> Bool -> IO ()
recordBuild store resolvedPath output path origin relocationChecked = do
  unless (isStorePathStrict (storeDirectory store) path) $
    ioError (userError ("path `" ++ C.unpack path ++ "' is not a valid store path"))
  either (ioError . userError) pure (assertNotReserved (storeDirectory store) path)
  resolved <- readDerivation resolvedPath
  let hash = resolvedHashOf resolved
      record = BuildRecord hash resolvedPath output path origin relocationChecked B.empty
      payload = canonicalBuildRecordPayload record
  signature <- signHash (sha256 payload)
  addRecord (database store) record { recordSignature = signature }

-- | C++ recordGoonixOutput: the fact plus the choice.
recordGoonixOutput :: Store -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> IO ()
recordGoonixOutput store originalPath resolvedPath output path origin = do
  recordBuild store resolvedPath output path origin False
  chooseOutput (database store) originalPath output path

-- | C++ goonixRecordFields: six fields per record (no resolved hash) for op 83,
-- seven (with it) for op 84.
goonixRecordFields :: [BuildRecord] -> Bool -> [ByteString]
goonixRecordFields records includeHash = concatMap fields records
  where
    fields record =
      (if includeHash then [recordResolvedHash record] else [])
      ++ [ recordResolvedDerivation record, recordOutput record, recordPath record
         , recordOrigin record, if recordRelocationChecked record then "1" else "0"
         , recordSignature record ]

-- | C++ queryGoonixBuildGraph: a bottom-up walk resolving against the choices
-- already made; facts plus record-backed routing hints.  Names, not input
-- availability, determine R; no query repairs a choice.
queryGoonixBuildGraph :: Store -> ByteString -> IO ([BuildRecord], [ByteString])
queryGoonixBuildGraph store unresolved = do
  (_, records, hints) <- visit (Set.empty, [], []) unresolved =<< readDerivation unresolved
  pure (records, hints)
  where
    visit state@(visited, records, hints) originalPath original
      | Set.member originalPath visited = pure state
      | otherwise = do
          let state' = (Set.insert originalPath visited, records, hints)
          state'' <- foldM (\acc (input, _) -> do
              dependency <- readDerivation input
              visit acc input dependency) state' (Map.toList (inputDrvs original))
          if not (goonixAddressed (Map.lookup "goonixAddressing" (environment original)))
            then pure state''
            else do
              let nameOf path drv output = case Map.lookup output (outputs drv) of
                    Nothing -> ioError (userError ("derivation has no output `" ++ C.unpack output ++ "'"))
                    Just out ->
                      if not (goonixAddressed (Map.lookup "goonixAddressing" (environment drv)))
                         || not (B.null (outputHash out))
                        then pure (outputPath out)
                        else chosenOutput (database store) path output
              -- A member with an unchosen input output is unresolved.
              missing <- or <$> forM (Map.toList (inputDrvs original)) (\(input, outs) -> do
                dependency <- readDerivation input
                or <$> forM (Set.toList outs) (\output -> B.null <$> nameOf input dependency output))
              if missing
                then pure state''
                else do
                  resolved <- resolveDerivation (storeDirectory store) originalPath original nameOf
                  let hash = resolvedHashOf resolved
                  foldM (\acc@(v, rs, hs) (output, _) -> do
                    chosen <- chosenOutput (database store) originalPath output
                    if B.null chosen
                      then pure acc
                      else do
                        outputRecords <- queryRecords (database store) hash output
                        let hint = if any (\r -> recordOutput r == output && recordPath r == chosen) outputRecords
                              then hs ++ [originalPath, output, chosen]
                              else hs
                        pure (v, rs ++ outputRecords, hint)) state'' (Map.toList (outputs original))