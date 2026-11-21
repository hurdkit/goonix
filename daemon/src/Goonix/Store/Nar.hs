{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Nar
  ( dumpNar
  , dumpNarToHandle
  , hashNar
  , hashNarWith
  , Nar (..)
  , encodeNar
  , decodeNar
  ) where

import Control.Exception (IOException, bracket, throwIO, try)
import Data.Bits ((.&.))
import GHC.IO.Exception (IOErrorType (EOF), ioe_type)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as L
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort, sortOn)
import Data.Word (Word64)
import qualified Data.Set as Set
import Goonix.Store.Hash
import System.Posix.ByteString (RawFilePath)
import System.Posix.Directory.ByteString (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files.ByteString (getSymbolicLinkStatus, isDirectory, isRegularFile, isSymbolicLink, readSymbolicLink, fileMode)
import System.Posix.Files (FileStatus, fileSize)
import System.Posix.IO.ByteString (closeFd, openFd, OpenMode (ReadOnly), defaultFileFlags)
import System.Posix.IO.ByteString (fdRead)

data Nar
  = Regular !Bool !ByteString
  | Symlink !ByteString
  | Directory ![(ByteString, Nar)]
  deriving (Eq, Show)

str :: ByteString -> Builder.Builder
str bytes = Builder.word32LE (fromIntegral (B.length bytes)) <> Builder.word32LE 0 <> Builder.byteString bytes <> Builder.byteString (B.replicate (pad (B.length bytes)) 0)
  where pad n = (8 - n `mod` 8) `mod` 8

encodeNar :: Nar -> ByteString
encodeNar nar = L.toStrict (Builder.toLazyByteString (str "nix-archive-1" <> node nar))
  where
    node (Regular executable contents) = str "(" <> str "type" <> str "regular"
      <> (if executable then str "executable" <> str "" else mempty)
      <> str "contents" <> Builder.word64LE (fromIntegral (B.length contents)) <> Builder.byteString contents
      <> Builder.byteString (B.replicate (pad (B.length contents)) 0) <> str ")"
    node (Symlink target) = str "(" <> str "type" <> str "symlink" <> str "target" <> str target <> str ")"
    node (Directory entries) = str "(" <> str "type" <> str "directory" <> foldMap entry (sortOn fst entries) <> str ")"
    entry (name, child) = str "entry" <> str "(" <> str "name" <> str name <> str "node" <> node child <> str ")"
    pad n = (8 - n `mod` 8) `mod` 8

decodeNar :: ByteString -> Either String Nar
decodeNar input = do
  (version, p) <- takeString input
  if version /= "nix-archive-1" then Left "not a NAR" else do
    (nar, rest) <- parseNode 256 p
    if B.null rest then Right nar else Left "trailing NAR bytes"
  where
    parseNode depth bytes
      | depth <= 0 = Left "nar directory nesting limit reached"
      | otherwise = do
          (open, p) <- takeString bytes
          (typeTag, p') <- takeString p
          (kind, p'') <- takeString p'
          if open /= "(" || typeTag /= "type" then Left "invalid NAR node" else case kind of
            "regular" -> do
              (executable, p3) <- parseExecutable p''
              (tag, p4) <- takeString p3
              (len, p5) <- takeWord64 p4
              if tag /= "contents" || len > fromIntegral (maxBound :: Int) || fromIntegral len > B.length p5
                then Left "invalid regular contents" else do
                  let (contents, after) = B.splitAt (fromIntegral len) p5
                  rest <- takePadding (padding (fromIntegral len)) after
                  (close, final) <- takeString rest
                  if close == ")" then Right (Regular executable contents, final) else Left "missing regular close"
            "symlink" -> do
              (tag, p3) <- takeString p''
              (target, p4) <- takeString p3
              (close, final) <- takeString p4
              if tag == "target" && close == ")" then Right (Symlink target, final) else Left "invalid symlink"
            "directory" -> parseDirectory depth p'' Nothing []
            _ -> Left "unknown NAR node type"
    parseExecutable bytes = do
      (tag, rest) <- takeString bytes
      if tag == "executable"
        then do
          (marker, after) <- takeString rest
          if B.null marker then pure (True, after) else Left "non-empty executable marker"
        else pure (False, bytes)
    parseDirectory depth bytes previous acc = do
      (tag, rest) <- takeString bytes
      if tag == ")" then Right (Directory (reverse acc), rest) else do
        (open, p') <- takeString rest
        (nameTag, p'') <- takeString p'
        (name, p''') <- takeString p''
        (nodeTag, p'''') <- takeString p'''
        if tag /= "entry" || open /= "(" || nameTag /= "name" || nodeTag /= "node"
          then Left "invalid directory entry"
          else if invalidName name then Left "NAR contains invalid file name"
          else if maybe False (name <=) previous then Left "NAR directory is not sorted"
          else do
            (child, after) <- parseNode (depth - 1) p''''
            (close, final) <- takeString after
            if close /= ")" then Left "missing entry close"
              else parseDirectory depth final (Just name) ((name, child):acc)
    invalidName name = B.null name || name == "." || name == ".."
      || B.any (\byte -> byte == 47 || byte == 0) name

takeString :: ByteString -> Either String (ByteString, ByteString)
takeString input = do
  (len, rest) <- takeInt input
  if len < 0 || len > B.length rest then Left "truncated NAR string" else do
    let (value, after) = B.splitAt len rest
    rest <- takePadding (padding len) after
    pure (value, rest)

takeInt :: ByteString -> Either String (Int, ByteString)
takeInt input
  | B.length input < 8 = Left "truncated NAR integer"
  | otherwise = Right (fromIntegral (littleWord32 (B.take 4 input)), B.drop 8 input)

takeWord64 :: ByteString -> Either String (Word64, ByteString)
takeWord64 input
  | B.length input < 8 = Left "truncated NAR word64"
  | otherwise = Right (littleWord64 (B.take 8 input), B.drop 8 input)

takePadding :: Int -> ByteString -> Either String ByteString
takePadding n input
  | B.length input < n = Left "truncated NAR padding"
  | B.any (/= 0) (B.take n input) = Left "non-zero NAR padding"
  | otherwise = Right (B.drop n input)

littleWord32 :: ByteString -> Word64
littleWord32 = littleWord64

littleWord64 :: ByteString -> Word64
littleWord64 bytes = sum [fromIntegral (B.index bytes i) * (256 ^ i) | i <- [0 .. B.length bytes - 1]]

dumpNar :: RawFilePath -> IO ByteString
dumpNar path = do
  chunks <- newIORef ([] :: [ByteString])
  dumpNarToHandle path (\bytes -> modifyIORef' chunks (bytes :))
  B.concat . reverse <$> readIORef chunks

hashNar :: RawFilePath -> IO Hash
hashNar path = do
  sink <- newHashSink SHA256
  dumpNarToHandle path (updateHashSink sink)
  finishHashSink sink

hashNarWith :: RawFilePath -> (ByteString -> (ByteString, Set.Set RawFilePath) -> (ByteString, Set.Set RawFilePath)) -> IO (Set.Set RawFilePath, Hash)
hashNarWith path update = do
  sink <- newHashSink SHA256
  state <- newIORef (B.empty, Set.empty)
  dumpNarToHandle path $ \chunk -> do
    updateHashSink sink chunk
    modifyIORef' state (update chunk)
  hash <- finishHashSink sink
  (_, found) <- readIORef state
  pure (found, hash)

dumpNarToHandle :: RawFilePath -> (ByteString -> IO ()) -> IO ()
dumpNarToHandle path emit = do
  emit (encodeString "nix-archive-1")
  dumpNode path emit
  where
    dumpNode p send = do
      status <- getSymbolicLinkStatus p
      emitString send "("
      emitString send "type"
      if isSymbolicLink status
        then do
          emitString send "symlink"
          target <- readSymbolicLink p
          emitString send "target"
          emitString send target
        else if isDirectory status
          then do
            emitString send "directory"
            entries <- directoryEntries p
            forM_ entries $ \entry -> do
              emitString send "entry"
              emitString send "("
              emitString send "name"
              emitString send entry
              emitString send "node"
              dumpNode (p <> "/" <> entry) send
              emitString send ")"
          else if isRegularFile status
            then do
              emitString send "regular"
              let executable = fileMode status .&. 0o100 /= 0
              if executable then emitString send "executable" >> emitString send "" else pure ()
              emitString send "contents"
              let size = narFileSize status
              emitWord64 send size
              sendFileContents p send
              send (B.replicate (padding (fromIntegral size)) 0)
            else throwIO (userError "unsupported file type")
      emitString send ")"

narFileSize :: FileStatus -> Word64
narFileSize = fromIntegral . fileSize

padding :: Int -> Int
padding n = (8 - n `mod` 8) `mod` 8

encodeString :: ByteString -> ByteString
encodeString bytes = encodeInt (B.length bytes) <> bytes <> B.replicate (padding (B.length bytes)) 0

emitString :: (ByteString -> IO ()) -> ByteString -> IO ()
emitString send = send . encodeString

emitWord64 :: (ByteString -> IO ()) -> Word64 -> IO ()
emitWord64 send n = send (L.toStrict (Builder.toLazyByteString (Builder.word64LE n)))

encodeInt :: Int -> ByteString
encodeInt n = L.toStrict (Builder.toLazyByteString (Builder.word32LE (fromIntegral n) <> Builder.word32LE 0))

sendFileContents :: RawFilePath -> (ByteString -> IO ()) -> IO ()
sendFileContents path send = bracket (openFd path ReadOnly defaultFileFlags) closeFd $ \fd -> do
  let loop = do
        result <- try (fdRead fd 1048576)
        case result of
          Left e | ioe_type e == EOF -> pure ()
                 | otherwise -> throwIO (e :: IOException)
          Right chunk -> unless (B.null chunk) (send chunk >> loop)
  loop

directoryEntries :: RawFilePath -> IO [RawFilePath]
directoryEntries path = bracket (openDirStream path) closeDirStream $ \stream -> do
  let loop acc = do
        entry <- readDirStream stream
        if B.null entry then pure (sort (reverse acc))
        else if entry == "." || entry == ".." then loop acc else loop (entry:acc)
  loop []
