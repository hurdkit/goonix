{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | goonix build records and output choices (HS-11, CA-5 storage layer).
-- Ported from the verified C++ nix/libstore/records.cc: permanent facts about
-- resolved derivations' outputs, independent of the store rows so they survive
-- collection, plus the per-original-derivation choices.  The canonical record
-- payload (goonix-record-v1\0) is what the daemon signs.
module Goonix.Store.Records
  ( BuildRecord (..)
  , RecordConflict (..)
  , initialiseRecords
  , canonicalBuildRecordPayload
  , addRecord
  , queryRecords
  , queryRecordsByPath
  , queryRecordsByResolved
  , queryRecordsWithLog
  , derivationsForPath
  , originalsForPath
  , chosenPaths
  , recordConflicts
  , chooseOutput
  , rechooseOutput
  , chosenOutput
  , allChoices
  , dropChoice
  ) where

import Control.Exception (throwIO, try)
import Control.Monad (foldM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Int (Int64)
import Goonix.Store.Ca (put64, putBytes)
import Goonix.Store.Database
import Goonix.Store.RecordSignature
import System.IO (hPutStrLn, stderr)

data BuildRecord = BuildRecord
  { recordResolvedHash :: !ByteString
  , recordResolvedDerivation :: !ByteString
  , recordOutput :: !ByteString
  , recordPath :: !ByteString
  , recordOrigin :: !ByteString
  , recordRelocationChecked :: !Bool
  , recordSignature :: !ByteString
  } deriving (Eq, Show)

data RecordConflict = RecordConflict
  { conflictResolvedHash :: !ByteString
  , conflictOutput :: !ByteString
  , conflictPathA :: !ByteString
  , conflictPathB :: !ByteString
  , conflictOrigin :: !ByteString
  } deriving (Eq, Show)

-- | The tables of records.cc, created if absent.
initialiseRecords :: Database -> IO ()
initialiseRecords db = do
  mapM_ (\sql -> execute db sql [])
    [ "create table if not exists GoonixBuildRecords (\
    \id integer primary key autoincrement not null,\
    \resolvedHash text not null,\
    \resolvedDerivation text not null,\
    \output text not null,\
    \path text not null,\
    \origin text not null,\
    \relocationChecked integer not null,\
    \signature text not null,\
    \unique(resolvedHash, output, path, origin, signature));"
    , "create index if not exists GoonixRecordLookup\
    \ on GoonixBuildRecords(resolvedHash, output);"
    , "create index if not exists GoonixRecordByPath\
    \ on GoonixBuildRecords(path);"
    , "create index if not exists GoonixRecordByResolved\
    \ on GoonixBuildRecords(resolvedDerivation);"
    , "create table if not exists GoonixChoices (\
    \derivation text not null,\
    \output text not null,\
    \path text not null,\
    \primary key(derivation, output));"
    , "create table if not exists GoonixConflicts (\
    \id integer primary key autoincrement not null,\
    \resolvedHash text not null,\
    \output text not null,\
    \pathA text not null,\
    \pathB text not null,\
    \origin text not null,\
    \unique(resolvedHash, output, pathA, pathB));"
    , "create index if not exists GoonixConflictLookup\
    \ on GoonixConflicts(resolvedHash, output);"
    ]
  withTransaction db $ do
    legacy <- queryValues db "select id, signature from GoonixBuildRecords where substr(signature, 1, 1) = '(' order by id;" []
    mapM_ migrate legacy
  where
    migrate [Integer id, Bytes raw] = do
      let signature = if "(" `B.isPrefixOf` raw then encodeRecordSignature raw else raw
      execute db "insert or ignore into GoonixBuildRecords (resolvedHash, resolvedDerivation, output, path, origin, relocationChecked, signature) select resolvedHash, resolvedDerivation, output, path, origin, relocationChecked, ? from GoonixBuildRecords where id = ?;" [Bytes signature, Integer id]
      execute db "delete from GoonixBuildRecords where id = ?;" [Integer id]
    migrate row = ioError (userError ("unexpected legacy record row: " ++ show row))

-- goonix-record-v1\0, the version 1, each of the five text fields framed with
-- its 64-bit length, then the relocation flag as a 64-bit 0/1.
canonicalBuildRecordPayload :: BuildRecord -> ByteString
canonicalBuildRecordPayload record =
  "goonix-record-v1\0" <> put64 1
  <> putBytes (recordResolvedHash record)
  <> putBytes (recordResolvedDerivation record)
  <> putBytes (recordOutput record)
  <> putBytes (recordPath record)
  <> putBytes (recordOrigin record)
  <> put64 (if recordRelocationChecked record then 1 else 0)

-- | A disagreement between two results for one resolved derivation is stored
-- as an ordered pair (C++ noteConflict); facts themselves are permanent.
noteConflict :: Database -> BuildRecord -> IO ()
noteConflict db record = do
  rows <- queryValues db
    "select distinct path from GoonixBuildRecords\
    \ where resolvedHash = ? and output = ? and path != ?;"
    [Bytes (recordResolvedHash record), Bytes (recordOutput record), Bytes (recordPath record)]
  mapM_ (insert . textOf) rows
  where
    textOf [Bytes path] = path
    textOf _ = B.empty
    insert other = do
      let (a, b) = if other < recordPath record
            then (other, recordPath record)
            else (recordPath record, other)
      execute db
        "insert or ignore into GoonixConflicts\
        \ (resolvedHash, output, pathA, pathB, origin) values (?, ?, ?, ?, ?);"
        [Bytes (recordResolvedHash record), Bytes (recordOutput record),
         Bytes a, Bytes b, Bytes (recordOrigin record)]

-- | C++ BuildRecords::add: validate, note conflicts, insert or ignore.
addRecord :: Database -> BuildRecord -> IO ()
addRecord db record = do
  if B.length (recordResolvedHash record) /= 64 || B.null (recordOutput record)
     || B.null (recordOrigin record) || B.null (recordSignature record)
    then ioError (userError "invalid or unsigned goonix build record")
    else do
      let signature = if "(" `B.isPrefixOf` recordSignature record
            then encodeRecordSignature (recordSignature record) else recordSignature record
          canonical = record { recordSignature = signature }
      noteConflict db canonical
      raw <- decodeRecordSignature signature
      existing <- queryValues db
        "select 1 from GoonixBuildRecords where resolvedHash = ? and resolvedDerivation = ? and output = ? and path = ? and origin = ? and relocationChecked = ? and (signature = ? or (substr(signature, 1, 1) = '(' and cast(signature as blob) = cast(? as blob))) limit 1;"
        [Bytes (recordResolvedHash canonical), Bytes (recordResolvedDerivation canonical),
         Bytes (recordOutput canonical), Bytes (recordPath canonical), Bytes (recordOrigin canonical),
         Integer (if recordRelocationChecked canonical then 1 else 0), Bytes signature, Bytes raw]
      if not (null existing) then pure () else execute db
        "insert or ignore into GoonixBuildRecords (resolvedHash, resolvedDerivation, output, path, origin, relocationChecked, signature) values (?, ?, ?, ?, ?, ?, ?);"
        [Bytes (recordResolvedHash canonical), Bytes (recordResolvedDerivation canonical),
         Bytes (recordOutput canonical), Bytes (recordPath canonical), Bytes (recordOrigin canonical),
         Integer (if recordRelocationChecked canonical then 1 else 0), Bytes signature]

readRecord :: [Value] -> IO BuildRecord
readRecord [Bytes resolvedHash, Bytes resolvedDerivation, Bytes output,
            Bytes path, Bytes origin, Integer checked, Bytes signature] = do
  loaded <- loadRecordSignature signature
  pure (BuildRecord resolvedHash resolvedDerivation output path origin (checked /= 0) loaded)
readRecord row = ioError (userError ("unexpected record row: " ++ show row))

recordColumns :: ByteString
recordColumns = "resolvedHash, resolvedDerivation, output, path,\
  \ origin, relocationChecked, signature"

-- | A pre-base64 stored S-expression is normalized at load.  Garbage in one
-- row does not poison an aggregate: retain valid siblings and name the bad
-- row in the warning.  Direct graph verification never calls this fallback.
queryRecordsWithLog :: (ByteString -> IO ()) -> Database -> ByteString -> [Value] -> IO [BuildRecord]
queryRecordsWithLog logWarning db sql arguments = do
  rows <- queryValues db sql arguments
  foldM collect [] rows
  where
    collect records row = do
      loaded <- try (readRecord row)
      case loaded of
        Right record -> pure (records ++ [record])
        Left (InvalidRecordSignature reason) -> do
          logWarning ("goonix: ignoring invalid record signature for `" <> field 1
            <> "', output `" <> field 2 <> "', path `" <> field 3 <> "': " <> C.pack reason)
          pure records
      where
        field index = case drop index row of
          Bytes bytes : _ -> bytes
          _ -> B.empty

queryRecordsLogged :: Database -> ByteString -> [Value] -> IO [BuildRecord]
queryRecordsLogged = queryRecordsWithLog (hPutStrLn stderr . C.unpack)

-- | C++ query: an empty output selects every output of the resolved hash.
queryRecords :: Database -> ByteString -> ByteString -> IO [BuildRecord]
queryRecords db resolvedHash output =
  queryRecordsLogged db
    ("select " <> recordColumns <> " from GoonixBuildRecords\
    \ where resolvedHash = ? and (? = '' or output = ?) order by id;")
    [Bytes resolvedHash, Bytes output, Bytes output]

queryRecordsByPath :: Database -> ByteString -> IO [BuildRecord]
queryRecordsByPath db path =
  queryRecordsLogged db
    ("select " <> recordColumns <> " from GoonixBuildRecords\
    \ where path = ? order by id;")
    [Bytes path]

queryRecordsByResolved :: Database -> ByteString -> IO [BuildRecord]
queryRecordsByResolved db resolved =
  queryRecordsLogged db
    ("select " <> recordColumns <> " from GoonixBuildRecords\
    \ where resolvedDerivation = ? order by id;")
    [Bytes resolved]

derivationsForPath :: Database -> ByteString -> IO [ByteString]
derivationsForPath db path =
  map textOf <$> queryValues db
    "select distinct resolvedDerivation from GoonixBuildRecords where path = ?;"
    [Bytes path]
  where
    textOf [Bytes value] = value
    textOf _ = B.empty

originalsForPath :: Database -> ByteString -> IO [ByteString]
originalsForPath db path =
  map textOf <$> queryValues db
    "select distinct derivation from GoonixChoices where path = ?;"
    [Bytes path]
  where
    textOf [Bytes value] = value
    textOf _ = B.empty

chosenPaths :: Database -> ByteString -> IO [ByteString]
chosenPaths db unresolved =
  map textOf <$> queryValues db
    "select path from GoonixChoices where derivation = ?;"
    [Bytes unresolved]
  where
    textOf [Bytes value] = value
    textOf _ = B.empty

recordConflicts :: Database -> ByteString -> ByteString -> IO [RecordConflict]
recordConflicts db resolvedHash output =
  map readConflict <$> queryValues db
    "select resolvedHash, output, pathA, pathB, origin from GoonixConflicts\
    \ where resolvedHash = ? and (? = '' or output = ?) order by id;"
    [Bytes resolvedHash, Bytes output, Bytes output]
  where
    readConflict [Bytes h, Bytes o, Bytes a, Bytes b, Bytes origin] =
      RecordConflict h o a b origin
    readConflict row = error ("unexpected conflict row: " ++ show row)

-- | C++ choose: insert or ignore (the first choice wins).
chooseOutput :: Database -> ByteString -> ByteString -> ByteString -> IO ()
chooseOutput db unresolved output realised =
  execute db "insert or ignore into GoonixChoices (derivation, output, path)\
    \ values (?, ?, ?);"
    [Bytes unresolved, Bytes output, Bytes realised]

-- | C++ rechoose: insert or replace.
rechooseOutput :: Database -> ByteString -> ByteString -> ByteString -> IO ()
rechooseOutput db unresolved output realised =
  execute db "insert or replace into GoonixChoices (derivation, output, path)\
    \ values (?, ?, ?);"
    [Bytes unresolved, Bytes output, Bytes realised]

-- | C++ choice: the empty path when there is none.
chosenOutput :: Database -> ByteString -> ByteString -> IO ByteString
chosenOutput db unresolved output = do
  rows <- queryValues db
    "select path from GoonixChoices where derivation = ? and output = ?;"
    [Bytes unresolved, Bytes output]
  pure $ case rows of
    [Bytes path]:_ -> path
    _ -> B.empty

allChoices :: Database -> ByteString -> IO [(ByteString, ByteString)]
allChoices db unresolved =
  map pairOf <$> queryValues db
    "select output, path from GoonixChoices where derivation = ?;"
    [Bytes unresolved]
  where
    pairOf [Bytes output, Bytes path] = (output, path)
    pairOf row = error ("unexpected choice row: " ++ show row)

dropChoice :: Database -> ByteString -> ByteString -> IO ()
dropChoice db unresolved output =
  execute db "delete from GoonixChoices where derivation = ? and output = ?;"
    [Bytes unresolved, Bytes output]