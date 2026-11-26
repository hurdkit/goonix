{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Exception (try)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef (modifyIORef', newIORef, readIORef)
import Goonix.Store.Database (Value (..), execute, queryValues, openReadWrite, closeDatabase)
import Goonix.Store.RecordSignature
import Goonix.Store.Records
import System.IO (hClose, openTempFile)

assert :: String -> Bool -> IO ()
assert name condition = unless condition (error ("record signature failed: " ++ name))

record :: B.ByteString -> B.ByteString -> B.ByteString -> BuildRecord
record path signature origin = BuildRecord (C.replicate 64 'a')
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x.drv" "out" path origin False signature

main :: IO ()
main = do
  let raw = B.concat [C.pack "(signature (hash sha256 \"XwH1KY", B.pack [0xa5, 0x00, 0x24, 0x5c, 0x62, 0x36, 0x6f, 0x42, 0x25, 0xb8], C.pack "\"))"]
  encoded <- loadRecordSignature raw
  assert "legacy raw high bytes normalize at load" (encoded == encodeRecordSignature raw)
  decoded <- decodeRecordSignature encoded
  assert "high bytes round-trip as ISO-8859-1 bytes" (decoded == raw)
  assert "wire encoding is ASCII" (B.all (< 128) encoded)
  refused <- try (decodeRecordSignature raw)
  case refused of
    Left (InvalidRecordSignature _) -> pure ()
    Right _ -> error "raw signature was accepted as base64"
  forM_ ["", "A", "AA=A", "AA=A", "AA==AAAA", "A===", "AA!A"] $ \bad -> do
    result <- try (decodeRecordSignature (C.pack bad))
    case result of
      Left (InvalidRecordSignature _) -> pure ()
      Right _ -> error ("malformed base64 accepted: " ++ bad)
  forM_ ["AA==", "AAA=", "AAAA", "YWJj", "////"] $ \valid -> do
    bytes <- decodeRecordSignature (C.pack valid)
    assert "strict decoder re-encodes exactly" (encodeRecordSignature bytes == C.pack valid)

  forM_ ["AB==", "AAB="] $ \accepted -> do
    _ <- decodeRecordSignature (C.pack accepted)
    assert "C++ noncanonical trailing-bit compatibility" True

  -- Insert one valid row and one garbage row for the same derivation, as
  -- records-test.cc does.  Aggregate reads keep the valid sibling and log the
  -- named warning; direct decoding still rejects the garbage field.
  (path, handle) <- openTempFile "/tmp" "goonix-record-signature.sqlite"
  hClose handle
  db <- openReadWrite path
  initialiseRecords db
  let good = record "/gnu/store/good" (encodeRecordSignature raw) "good-test"
      bad = record "/gnu/store/bad" "not base64" "bad-test"
  addRecord db good { recordSignature = raw }
  storedGood <- queryValues db "select signature from GoonixBuildRecords where path = ?;" [Bytes (recordPath good)]
  assert "raw insertion stores canonical base64 with length-delimited bytes" (storedGood == [[Bytes encoded]])
  execute db "insert into GoonixBuildRecords (resolvedHash,resolvedDerivation,output,path,origin,relocationChecked,signature) values (?,?,?,?,?,?,?);"
    [Bytes (recordResolvedHash bad), Bytes (recordResolvedDerivation bad), Bytes (recordOutput bad),
     Bytes (recordPath bad), Bytes (recordOrigin bad), Integer 0, Bytes (recordSignature bad)]
  warnings <- newIORef []
  let recordColumnsForTest = "resolvedHash, resolvedDerivation, output, path, origin, relocationChecked, signature"
  execute db "insert into GoonixBuildRecords (resolvedHash,resolvedDerivation,output,path,origin,relocationChecked,signature) values (?,?,?,?,?,?,?);"
    [Bytes (C.replicate 64 'b'), Bytes (recordResolvedDerivation good), Bytes "out",
     Bytes "/gnu/store/legacy", Bytes "legacy-test", Integer 0, Bytes raw]
  let legacyRecord = record "/gnu/store/legacy" encoded "legacy-test"
  addRecord db legacyRecord { recordResolvedHash = C.replicate 64 'b' }
  storedLegacy <- queryValues db "select signature from GoonixBuildRecords where resolvedHash = ? and output = 'out';" [Bytes (C.replicate 64 'b')]
  assert ("legacy raw and encoded reimport are one logical row; stored=" ++ show storedLegacy) (storedLegacy == [[Bytes raw]])
  reimported <- queryRecords db (C.replicate 64 'b') "out"
  assert "raw twin reimport returns the canonical signature" (map recordSignature reimported == [encoded])
  execute db "insert into GoonixBuildRecords (resolvedHash,resolvedDerivation,output,path,origin,relocationChecked,signature) values (?,?,?,?,?,?,?);"
    [Bytes (C.replicate 64 'b'), Bytes (recordResolvedDerivation good), Bytes "out",
     Bytes "/gnu/store/legacy", Bytes "legacy-test", Integer 0, Bytes encoded]
  twins <- queryValues db "select count(*) from GoonixBuildRecords where resolvedHash = ? and output = 'out';" [Bytes (C.replicate 64 'b')]
  assert "fixture really contains raw and encoded twins" (twins == [[Integer 2]])
  initialiseRecords db
  migrated <- queryValues db "select signature from GoonixBuildRecords where resolvedHash = ? and output = 'out';" [Bytes (C.replicate 64 'b')]
  assert ("open-time migration collapses raw and encoded twins; stored=" ++ show migrated) (migrated == [[Bytes encoded]])
  initialiseRecords db
  reopened <- queryValues db "select signature from GoonixBuildRecords where resolvedHash = ? and output = 'out';" [Bytes (C.replicate 64 'b')]
  assert "signature migration is idempotent" (reopened == migrated)
  byHash <- queryRecordsWithLog (\warning -> modifyIORef' warnings (warning :)) db
    ("select " <> recordColumnsForTest <> " from GoonixBuildRecords where resolvedHash = ? and output = ? order by id;")
    [Bytes (recordResolvedHash good), Bytes "out"]
  assert "mixed aggregate retains valid row" (map recordSignature byHash == [recordSignature good])
  legacy <- queryRecords db (C.replicate 64 'b') "out"
  assert "stored legacy row is normalized" (map recordSignature legacy == [encoded])
  byPath <- queryRecordsByPath db "/gnu/store/good"
  byResolved <- queryRecordsByResolved db (recordResolvedDerivation good)
  assert "all aggregate readers retain valid row" (length byPath == 1 && length byResolved == 2)
  direct <- try (decodeRecordSignature "not base64")
  case direct of
    Left (InvalidRecordSignature _) -> pure ()
    Right _ -> error "direct invalid signature verification accepted"
  closeDatabase db
  logged <- readIORef warnings
  assert "one named invalid-signature warning" (length logged == 1)
  assert "warning names derivation output and path" $ case logged of
    [warning] -> B.isInfixOf (recordResolvedDerivation good) warning
      && B.isInfixOf "output `out'" warning && B.isInfixOf "path `/gnu/store/bad'" warning
    _ -> False
  putStrLn "record signature properties: PASS"
