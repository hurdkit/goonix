{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
-- | HS-11 CA-0 shared vectors (Haskell side).  Mirrors nix/ca-test
-- --shared-vectors: tokens, placeholder, tree hashes, directory ordering,
-- content-addressed and resolved-addressed paths.  The shared input and
-- expected-output set is tests/ca-vectors.json; neither side calls the other.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Word (Word8)
import Goonix.Store.Ca
import Goonix.Store.Derivation (parseDerivation, writeDerivation, outputs, inputDrvs)
import Goonix.Store.Hash (Hash (..), HashAlgorithm (..), sha256)
import System.Directory (createDirectoryIfMissing, removePathForcibly, getTemporaryDirectory)
import System.Exit (die)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Posix.Process (getProcessID)

check :: String -> Bool -> IO ()
check name condition = unless condition (die ("FAIL: " ++ name))

-- A minimal strict JSON reader for the shared vectors (test code only).
data JSON = JNull | JBool Bool | JNum Double | JStr ByteString | JArr [JSON] | JObj [(ByteString, JSON)]
  deriving (Show)

main :: IO ()
main = do
  raw <- B.readFile "tests/ca-vectors.json"
  let vectors = parseJSON raw
      field obj name = case lookupObj obj name of
        JStr s -> s
        other -> error ("field " ++ C.unpack name ++ " not a string: " ++ show other)
      num obj name = case lookupObj obj name of
        JNum n -> n
        other -> error ("field " ++ C.unpack name ++ " not a number: " ++ show other)
      arr obj name = case lookupObj obj name of
        JArr a -> a
        other -> error ("field " ++ C.unpack name ++ " not an array: " ++ show other)
      store = "/gnu/store"
  check "shared vector format is 1" (num vectors "format" == 1)
  let tokens = lookupObj vectors "tokens"
      out = field tokens "out"
      lib = field tokens "lib"
  check "shared self token vector" (selfToken "out" == out)
  check "shared lib token vector" (selfToken "lib" == lib)
  check "shared token path vector" (tokenPath store "out" "hello-1.0" == store <> "/" <> out <> "-hello-1.0")
  let placeholder = lookupObj vectors "placeholder"
      phPath = makePlaceholder store (field placeholder "derivationBytes")
                 (field placeholder "output") (field placeholder "name")
  check "shared placeholder vector"
    (phPath == store <> "/" <> field placeholder "hash" <> "-" <> field placeholder "name")

  withTempDir $ \root -> do
    let trees = arr vectors "trees"
    forM_ trees $ \vector -> do
      let name = field vector "name"
          kind = field vector "kind"
          path = root <> "/" <> name
      case kind of
        "regular" -> do
          let bytes = B.pack [round n | JNum n <- arr vector "bytes"]
          B.writeFile (C.unpack path) bytes
          setFileMode (C.unpack path) (if num vector "executable" /= 0 then 0o555 else 0o444)
        "symlink" -> createSymbolicLink (C.unpack (field vector "target")) (C.unpack path)
        "directory" -> do
          createDirectoryIfMissing True (C.unpack path)
          forM_ (arr vector "entries") $ \entry -> do
            let bytes = B.pack [round n | JNum n <- arr entry "bytes"]
                child = path <> "/" <> field entry "name"
            B.writeFile (C.unpack child) bytes
            setFileMode (C.unpack child) 0o444
        _ -> die ("unknown shared tree vector kind: " ++ C.unpack kind)
      hash <- treeHash path
      check ("shared tree vector: " ++ C.unpack name) (printHashHex hash == field vector "sha256")
    -- Directory ordering: create in reverse lexical order.
    let ordered = root <> "/ordered"
    createDirectoryIfMissing True (C.unpack ordered)
    B.writeFile (C.unpack (ordered <> "/z-last")) "z"
    B.writeFile (C.unpack (ordered <> "/a-first")) "a"
    createSymbolicLink "m-target" (C.unpack (ordered <> "/m-link"))
    setFileMode (C.unpack (ordered <> "/z-last")) 0o444
    setFileMode (C.unpack (ordered <> "/a-first")) 0o444
    orderedHash <- treeHash ordered
    check "shared directory entry ordering vector"
      (printHashHex orderedHash == field (lookupObj vectors "orderedDirectory") "sha256")

    let content = lookupObj vectors "contentPaths"
        empty = Hash SHA256 (decodeHex (field (head trees) "sha256"))
        references = sort [s | JStr s <- arr content "references"]
    check "shared content path vector"
      (contentAddressedPath store "out" "hello" empty [] == field content "withoutReferences")
    check "shared content path with sorted references vector"
      (contentAddressedPath store "out" "hello" empty references == field content "withReferences")

    let resolved = lookupObj vectors "resolvedDerivation"
        bytes = field resolved "bytes"
    case parseDerivation bytes of
      Left err -> die ("resolved derivation parse: " ++ err)
      Right parsed -> check "shared resolved derivation canonical bytes" (writeDerivation parsed == bytes)
    check "shared resolved-addressed path vector"
      (resolvedAddressedPath store "out" "hello" bytes == field resolved "resolvedPath")
    check "shared resolved-addressed sibling path vector"
      (resolvedAddressedPath store "lib" "hello-lib" bytes == field resolved "resolvedLibPath")

    let unresolved = lookupObj vectors "unresolvedDerivation"
        unresolvedBytes = field unresolved "bytes"
    case parseDerivation unresolvedBytes of
      Left err -> die ("unresolved derivation parse: " ++ err)
      Right parsed -> do
        check "shared unresolved derivation canonical bytes" (writeDerivation parsed == unresolvedBytes)
        check "shared unresolved derivation has two outputs and an input derivation"
          (Map.size (outputs parsed) == 2 && Map.size (inputDrvs parsed) == 1)
    check "shared placeholder bytes match the unresolved derivation serializer"
      (makePlaceholder store unresolvedBytes (field unresolved "output") (field unresolved "name")
        == store <> "/" <> field unresolved "placeholderHash" <> "-" <> field unresolved "name")
  putStrLn "CA-0 shared vectors (Haskell): PASS"
  where
    withTempDir action = do
      tmp <- getTemporaryDirectory
      pid <- getProcessID
      let root = C.pack (tmp <> "/goonix-ca0-vectors-" <> show pid)
      createDirectoryIfMissing True (C.unpack root)
      result <- action root
      removePathForcibly (C.unpack root)
      pure result
    printHashHex = B.concatMap (\w -> B.pack [hexByte (w `div` 16), hexByte (w `mod` 16)]) . hashDigest
    hexByte :: Word8 -> Word8
    hexByte n = if n < 10 then 48 + n else 87 + n
    decodeHex = B.pack . go . C.unpack
      where go (a:b:rest) = fromIntegral (hexVal a * 16 + hexVal b) : go rest
            go _ = []
            hexVal c | c >= '0' && c <= '9' = fromEnum c - 48
                   | otherwise = fromEnum c - 87
    lookupObj (JObj kvs) name = case lookup name kvs of
      Just v -> v
      Nothing -> error ("missing key: " ++ C.unpack name)
    lookupObj other _ = error ("not an object: " ++ show other)

-- Minimal JSON parser (strict, test-only).
parseJSON :: ByteString -> JSON
parseJSON raw = case runParser (C.unpack raw) of
  (value, rest) | all (`elem` (" \t\r\n" :: String)) rest -> value
  _ -> error "JSON parse leftover"
  where
    runParser s = let (v, r) = parseValue (dropSpace s) in (v, dropSpace r)
    dropSpace = dropWhile (`elem` (" \t\r\n" :: String))
    parseValue ('"':rest) = let (str, r) = parseString rest in (JStr (C.pack str), r)
    parseValue ('{':rest) = parseObject rest []
    parseValue ('[':rest) = parseArray rest []
    parseValue ('t':'r':'u':'e':rest) = (JBool True, rest)
    parseValue ('f':'a':'l':'s':'e':rest) = (JBool False, rest)
    parseValue ('n':'u':'l':'l':rest) = (JNull, rest)
    parseValue s = let (n, r) = span (\c -> c `elem` ("-0123456789.eE+" :: String)) s
                   in (JNum (read n), r)
    parseString ('"':rest) = ("", rest)
    parseString ('\\':'"':rest) = let (s, r) = parseString rest in ('"':s, r)
    parseString ('\\':'\\':rest) = let (s, r) = parseString rest in ('\\':s, r)
    parseString ('\\':'n':rest) = let (s, r) = parseString rest in ('\n':s, r)
    parseString ('\\':'t':rest) = let (s, r) = parseString rest in ('\t':s, r)
    parseString ('\\':'/':rest) = let (s, r) = parseString rest in ('/':s, r)
    parseString (c:rest) = let (s, r) = parseString rest in (c:s, r)
    parseString [] = error "unterminated string"
    parseObject s acc = case dropSpace s of
      ('}':rest) -> (JObj (reverse acc), rest)
      ('"':rest) ->
        let (key, r1) = parseString rest
            (':':r2) = dropSpace r1
            (value, r3) = parseValue (dropSpace r2)
        in case dropSpace r3 of
             (',':r4) -> parseObject r4 ((C.pack key, value):acc)
             ('}':r4) -> (JObj (reverse ((C.pack key, value):acc)), r4)
             _ -> error "object parse"
      _ -> error "object key"
    parseArray s acc = case dropSpace s of
      (']':rest) -> (JArr (reverse acc), rest)
      _ -> let (value, r1) = parseValue (dropSpace s)
           in case dropSpace r1 of
                (',':r2) -> parseArray r2 (value:acc)
                (']':r2) -> (JArr (reverse (value:acc)), r2)
                _ -> error "array parse"