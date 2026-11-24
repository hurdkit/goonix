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

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Int (Int64)
import Goonix.Store.Ca (put64, putBytes)
import Goonix.Store.Database

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
initialiseRecords db = mapM_ (\sql -> execute db sql [])
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

-- | The canonical payload (C++ canonicalBuildRecordPayload): the domain
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
      noteConflict db record
      execute db
        "insert or ignore into GoonixBuildRecords\
        \ (resolvedHash, resolvedDerivation, output, path, origin,\
        \ relocationChecked, signature) values (?, ?, ?, ?, ?, ?, ?);"
        [Bytes (recordResolvedHash record), Bytes (recordResolvedDerivation record),
         Bytes (recordOutput record), Bytes (recordPath record),
         Bytes (recordOrigin record),
         Integer (if recordRelocationChecked record then 1 else 0),
         Bytes (recordSignature record)]

readRecord :: [Value] -> BuildRecord
readRecord [Bytes resolvedHash, Bytes resolvedDerivation, Bytes output,
            Bytes path, Bytes origin, Integer checked, Bytes signature] =
  BuildRecord resolvedHash resolvedDerivation output path origin (checked /= 0) signature
readRecord row = error ("unexpected record row: " ++ show row)

recordColumns :: ByteString
recordColumns = "resolvedHash, resolvedDerivation, output, path,\
  \ origin, relocationChecked, signature"

-- | C++ query: an empty output selects every output of the resolved hash.
queryRecords :: Database -> ByteString -> ByteString -> IO [BuildRecord]
queryRecords db resolvedHash output =
  map readRecord <$> queryValues db
    ("select " <> recordColumns <> " from GoonixBuildRecords\
    \ where resolvedHash = ? and (? = '' or output = ?) order by id;")
    [Bytes resolvedHash, Bytes output, Bytes output]

queryRecordsByPath :: Database -> ByteString -> IO [BuildRecord]
queryRecordsByPath db path =
  map readRecord <$> queryValues db
    ("select " <> recordColumns <> " from GoonixBuildRecords\
    \ where path = ? order by id;")
    [Bytes path]

queryRecordsByResolved :: Database -> ByteString -> IO [BuildRecord]
queryRecordsByResolved db resolved =
  map readRecord <$> queryValues db
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