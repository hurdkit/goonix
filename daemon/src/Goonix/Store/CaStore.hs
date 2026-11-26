{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | goonix CA store operations (HS-11): the records table wired to the store,
-- realised-output selection, resolved-derivation writing, signed build facts,
-- and the read-only graph query.  Ported from nix/libstore/local-store-ca.cc.
module Goonix.Store.CaStore
  ( initCaRecords
  , chosenOutputForCurrentGraph
  , realisedOutputPath
  , selectGoonixOutput
  , selectGoonixOutputs
  , writeResolvedDerivation
  , resolvedDerivationPath
  , recordBuild
  , recordGoonixOutput
  , queryGoonixBuildGraph
  , queryGoonixBuildGraphWithLog
  , goonixRecordFields
  , importGoonixGraph
  , resolvedHashOf
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Goonix.Store.Archive (signHash, verifySignature)
import Goonix.Store.Ca (assertNotReserved, goonixAddressed, isReservedStorePath)
import Goonix.Store.CaBuild (resolveDerivation, checkResolvedDerivation, isStorePathStrict)
import Goonix.Store.Database
import Goonix.Store.Derivation
import Goonix.Store.Base32 (encodeBase16)
import Goonix.Store.Hash (sha256)
import Goonix.Store.Path (storePathToName, makeTextPath)
import Goonix.Store.ReadOnly
import Goonix.Store.RecordSignature
import Goonix.Store.Records
import Goonix.Store.Writing (addTextToStore)
import System.Posix.Types (Fd)
import System.IO (hPutStrLn, stderr)

-- | Create the records tables if absent (C++ initialiseGoonixRecords).
initCaRecords :: Store -> IO ()
initCaRecords store = initialiseRecords (database store)

-- | The hex SHA-256 of a derivation's canonical bytes (C++ resolvedHash).
resolvedHashOf :: Derivation -> ByteString
resolvedHashOf = resolvedHashOfBytes . writeDerivation

resolvedHashOfBytes :: ByteString -> ByteString
resolvedHashOfBytes = encodeBase16 . sha256

readDerivation :: ByteString -> IO Derivation
readDerivation path = do
  bytes <- B.readFile (C.unpack path)
  either (ioError . userError) pure (parseDerivation bytes)

-- | A stored choice belongs to the current input graph only when the resolved
-- derivation still has an authenticated record for it.  C++
-- chosenOutputForCurrentGraph drops it otherwise, before selecting a candidate
-- for substitution, and says so: the message is how a client learns that an
-- imported choice lost to an input built here.  A valid local choice survives
-- absent historical inputs; a choice dropped because an input has no choice at
-- all is dropped without a message, as in C++.
chosenOutputForCurrentGraph :: (ByteString -> IO ()) -> Store -> ByteString -> ByteString -> IO ByteString
chosenOutputForCurrentGraph report store unresolved output = do
  current <- chosenOutput (database store) unresolved output
  if B.null current then pure B.empty else do
    original <- readDerivation unresolved
    if not (goonixAddressed (Map.lookup "goonixAddressing" (environment original)))
      then pure current
      else do
        let nameOf path drv name = case Map.lookup name (outputs drv) of
              Nothing -> pure B.empty
              Just out | not (goonixAddressed (Map.lookup "goonixAddressing" (environment drv)))
                          || not (B.null (outputHash out)) -> pure (outputPath out)
              Just _ -> chosenOutput (database store) path name
        missing <- or <$> forM (Map.toList (inputDrvs original)) (\(path, names) -> do
          drv <- readDerivation path
          or <$> forM (Set.toList names) (\name -> B.null <$> nameOf path drv name))
        currentValid <- isValidPath store current
        if missing && currentValid then pure current else do
          resolved <- resolveDerivation (storeDirectory store) unresolved original nameOf
          records <- queryRecords (database store) (resolvedHashOf resolved) output
          if any (\record -> recordPath record == current) records
            then pure current
            else do
              unless missing $
                report ("goonix: dropping choice `" <> current <> "' of `" <> unresolved
                  <> "': input choices changed\n")
              dropChoice (database store) unresolved output
              pure B.empty

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
  addTextToStore rootFd store (name <> ".drv") (writeDerivation resolved) references
  where
    name0 = storePathToName (storeDirectory store) originalPath
    name = if ".drv" `B.isSuffixOf` name0 then B.dropEnd 4 name0 else name0
    references = Set.toList (inputSrcs resolved)

resolvedDerivationPath :: Fd -> Store -> ByteString -> Derivation -> IO ByteString
resolvedDerivationPath _rootFd store originalPath resolved = do
  let name0 = storePathToName (storeDirectory store) originalPath
      name = if ".drv" `B.isSuffixOf` name0 then B.dropEnd 4 name0 else name0
      references = Set.toList (inputSrcs resolved)
  pure (makeTextPath (storeDirectory store) (name <> ".drv") (writeDerivation resolved) references)

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
  signature <- encodeRecordSignature <$> signHash (sha256 payload)
  addRecord (database store) record { recordSignature = signature }

-- | C++ recordGoonixOutput: the fact plus the choice.
recordGoonixOutput :: Store -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> IO ()
recordGoonixOutput store originalPath resolvedPath output path origin = do
  recordBuild store resolvedPath output path origin False
  chooseOutput (database store) originalPath output path

-- | C++ importGoonixBuildGraph: a server hint may name an input output, but R
-- is computed from local derivations.  Every matching record is authenticated
-- against the locally computed resolved bytes before any record or choice is
-- adopted.  One transaction rolls back the whole graph on a refusal.
importGoonixGraph :: Fd -> Store -> ByteString
  -> [(ByteString, ByteString, ByteString, ByteString, ByteString, Bool, ByteString)]
  -> [(ByteString, ByteString, ByteString)] -> IO ()
importGoonixGraph rootFd store unresolved offered hints = do
  resolved <- newIORef Map.empty
  visiting <- newIORef Set.empty
  let hintMap = Map.fromList [((original, output), path) | (original, output, path) <- hints]
      offeredRecords = [BuildRecord hash resolvedPath output path origin checked signature
                       | (hash, resolvedPath, output, path, origin, checked, signature) <- offered]
      hintFor path output = Map.lookup (path, output) hintMap
      load path = readDerivation path
      resolve originalPath = do
        seen <- readIORef visiting
        if Set.member originalPath seen then pure () else do
          modifyIORef' visiting (Set.insert originalPath)
          original <- load originalPath
          mapM_ (resolve . fst) (Map.toList (inputDrvs original))
          when (goonixAddressed (Map.lookup "goonixAddressing" (environment original))) $ do
            let nameOf path drv output = case Map.lookup output (outputs drv) of
                  Nothing -> throwIO (StoreError (C.pack ("derivation has no output `" ++ C.unpack output ++ "'")) 1)
                  Just out | not (goonixAddressed (Map.lookup "goonixAddressing" (environment drv)))
                              || not (B.null (outputHash out)) -> pure (outputPath out)
                  Just _ -> do
                    own <- chosenOutput (database store) path output
                    if not (B.null own) then pure own else case hintFor path output of
                      Nothing -> pure B.empty
                      Just hinted -> pure $ if any (\record -> recordOutput record == output && recordPath record == hinted) offeredRecords
                        then hinted else B.empty
            missing <- or <$> forM (Map.toList (inputDrvs original)) (\(input, outs) -> do
              dependency <- load input
              or <$> forM (Set.toList outs) (\output -> B.null <$> nameOf input dependency output))
            unless missing $ do
              r <- resolveDerivation (storeDirectory store) originalPath original nameOf
              -- importGoonixBuildGraph computes this path only.  C++ does not
              -- register it yet: a selected input output may still need to be
              -- substituted before the resolved text can name it as a reference.
              path <- resolvedDerivationPath rootFd store originalPath r
              modifyIORef' resolved (Map.insert originalPath (r, path))
      adopt settledRef originalPath = do
        settled <- readIORef settledRef
        if Set.member originalPath settled then pure () else do
          modifyIORef' settledRef (Set.insert originalPath)
          original <- load originalPath
          mapM_ (adopt settledRef . fst) (Map.toList (inputDrvs original))
          local <- Map.lookup originalPath <$> readIORef resolved
          case local of
            Nothing -> pure ()
            Just (r, resolvedPath) -> do
              let hash = resolvedHashOf r
              forM_ (Map.keys (outputs original)) $ \output -> do
                current <- chosenOutput (database store) originalPath output
                let hinted = maybe B.empty id (hintFor originalPath output)
                backed <- foldM (\found record ->
                  if recordResolvedHash record /= hash || recordOutput record /= output
                    then pure found
                    else do
                      when (recordResolvedDerivation record /= resolvedPath) $
                        throwIO (StoreError "goonix graph record does not match local resolved derivation" 1)
                      authenticateGraphRecord store record (writeDerivation r)
                      pure (found || recordPath record == hinted)) False offeredRecords
                when backed $
                  if not (B.null current)
                    then when (hinted /= current) $
                      selectGoonixOutput store originalPath output hash hinted False >> pure ()
                    else rechooseOutput (database store) originalPath output hinted
  resolve unresolved
  retryBusy $ withTransaction (database store) $ do
    settled <- newIORef Set.empty
    adopt settled unresolved
  where
    -- verifySignature runs `guix authenticate', which reads the configured
    -- signing public keys/ACL.  It returns the SHA-256 digest the signer
    -- actually signed; only that digest is compared to the canonical record.
    authenticateGraphRecord store' record resolvedBytes = do
      rawSignature <- decodeRecordSignature (recordSignature record)
      verified <- try (verifySignature rawSignature)
      verifiedHash <- case verified of
        Left (exception :: SomeException) ->
          throwIO (StoreError (C.pack ("goonix build record authentication failed: " ++ show exception)) 1)
        Right value -> pure value
      let expected = resolvedHashOfBytes (canonicalBuildRecordPayload record)
      -- The record's path and origin are authenticated fields.  Check that
      -- they name this store before adding the fact; no filesystem mutation.
      when (not (isStorePathStrict (storeDirectory store') (recordPath record))
            || isReservedStorePath (storeDirectory store') (recordPath record)) $
        throwIO (StoreError "goonix build record does not name a valid realised store path" 1)
      when (not (isStorePathStrict (storeDirectory store') (recordResolvedDerivation record))
            || not (".drv" `B.isSuffixOf` recordResolvedDerivation record)) $
        throwIO (StoreError "goonix build record does not name a resolved derivation" 1)
      when (B.length (recordResolvedHash record) /= 64
            || B.null (recordOutput record) || B.null (recordOrigin record)
            || B.null (recordSignature record)) $
        throwIO (StoreError "invalid or unsigned goonix build record" 1)
      when (verifiedHash /= expected) $
        throwIO (StoreError "goonix build record signature does not match its fields" 1)
      when (resolvedHashOfBytes resolvedBytes /= recordResolvedHash record) $
        throwIO (StoreError "goonix build record does not match resolved derivation content" 1)
      addRecord (database store') record

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
queryGoonixBuildGraph store = queryGoonixBuildGraphWithLog store (hPutStrLn stderr . C.unpack)

queryGoonixBuildGraphWithLog :: Store -> (ByteString -> IO ()) -> ByteString -> IO ([BuildRecord], [ByteString])
queryGoonixBuildGraphWithLog store logWarning unresolved = do
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
                        outputRecords <- queryRecordsWithLog logWarning (database store)
                          ("select resolvedHash, resolvedDerivation, output, path, origin, relocationChecked, signature from GoonixBuildRecords where resolvedHash = ? and output = ? order by id;")
                          [Bytes hash, Bytes output]
                        let hint = if any (\r -> recordOutput r == output && recordPath r == chosen) outputRecords
                              then hs ++ [originalPath, output, chosen]
                              else hs
                        pure (v, rs ++ outputRecords, hint)) state'' (Map.toList (outputs original))