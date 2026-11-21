{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Main (main) where

import Control.Exception (bracket, throwIO)
import Data.Either (fromRight)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import Goonix.Store.Base32
import Goonix.Store.Derivation
import Goonix.Store.Hash
import Goonix.Store.Nar
import Goonix.Store.Path
import Goonix.Store.References
import Goonix.Store.Wire
import System.Posix.Files.ByteString (removeLink)
import System.Posix.IO.ByteString
  ( OpenMode (WriteOnly), closeFd, creat, defaultFileFlags, fdWrite, openFd, trunc )

main :: IO ()
main = do
  checkEncodings
  checkNars
  checkWire
  checkDerivations
  checkPaths
  checkReferences
  putStrLn "format properties passed"

checkEncodings :: IO ()
checkEncodings = do
  forM_ [0 .. 80] $ \n -> do
    let bytes = B.pack (take n (cycle [0, 1, 2, 127, 128, 254, 255, 42]))
    decodeBase16 (encodeBase16 bytes) @?= Right bytes
    decodeBase32 (encodeBase32 bytes) @?= Right bytes
  forM_ [minBound .. maxBound] $ \algorithm -> do
    algorithmFromName (algorithmName algorithm) @?= Right algorithm
    sink <- newHashSink algorithm
    updateHashSink sink "ab"
    updateHashSink sink "c"
    streamed <- finishHashSink sink
    streamed @?= Hash algorithm (hashBytes algorithm "abc")
    B.length (hashDigest streamed) @?= digestLength algorithm

checkNars :: IO ()
checkNars = forM_ [0 .. 255 :: Int] $ \n -> do
  let bytes = B.pack (take n (cycle [0..255]))
      nar = Directory [("z", Regular False ""), ("a", Regular True bytes), ("b", Symlink "../a")]
      encoded = encodeNar nar
  case decodeNar encoded of
    Left err -> throwIO (userError err)
    Right parsed -> encodeNar parsed @?= encoded
  decodeNar (encoded <> "junk") @?= Left "trailing NAR bytes"

checkWire :: IO ()
checkWire = do
  forM_ [0 .. 255 :: Int] $ \n -> do
    let bytes = B.pack (take n (cycle [0..255]))
        wire = encodeStrings ["", bytes, C.replicate 17 'x']
    case decodeStrings (wire <> "trailing") of
      Left err -> throwIO (userError (show err))
      Right decoded -> decoded @?= ["", bytes, C.replicate 17 'x']
  forM_ operations $ \operation -> operationByCode (operationCode operation) @?= Just operation
  map operationCode operations @?= [1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 80, 81]
  forM_ [0 .. 255] $ \n -> decodeInt (encodeInt n) @?= Right n
  forM_ [0, 1, 255, 256, 65535, 65536, maxBound :: Word64] $ \n ->
    decodeWord64 (encodeWord64 n) @?= Right n
  decodeString (encodeString "x" <> B.replicate 1 1) @?= Right "x"
  let badPadding = encodeInt 1 <> "x" <> B.replicate 7 1
  decodeString badPadding @?= Left "non-zero padding"

checkDerivations :: IO ()
checkDerivations = do
  let fixed = Derivation
        (Map.singleton "out" (DerivationOutput "/gnu/store/output" "r:sha256" "abcd"))
        Map.empty Set.empty "x86_64-linux" "/bin/sh" ["-c", "true"]
        (Map.fromList [("out", "/gnu/store/output"), ("other", "unchanged")])
      ordinary = fixed
        { outputs = Map.singleton "out" (DerivationOutput "/gnu/store/output" "" "")
        , inputDrvs = Map.singleton "/gnu/store/input.drv" (Set.fromList ["dev", "out"])
        }
      masked = ordinary
        { inputDrvs = Map.singleton (encodeBase16 (sha256 "input")) (Set.fromList ["dev", "out"]) }
  parseDerivation (writeDerivation fixed) @?= Right fixed
  parseDerivation (writeDerivation ordinary) @?= Right ordinary
  isFixedOutput fixed @?= True
  isFixedOutput ordinary @?= False
  environment (blankOutputPaths ordinary) @?= Map.fromList [("out", ""), ("other", "unchanged")]
  case hashDerivationModulo ordinary (const (Right (Hash SHA256 (sha256 "input")))) of
    Left err -> throwIO (userError err)
    Right actual -> actual @?= Hash SHA256 (sha256 (writeDerivation masked))
  parseHashInfo (DerivationOutput "" "r:sha256" "abcd") @?= Right (True, SHA256, B.pack [0xab, 0xcd])

checkPaths :: IO ()
checkPaths = do
  makeStorePath "/gnu/store" "source" (sha256 "hello") "hello"
    @?= "/gnu/store/gsgncr9f5qhqm7hci473bfclgclwilxv-hello"
  let digest = fromRight B.empty (decodeBase16 "00b55e2a318800d887e847f3466c4774b7e5a8d441ddc5c3a3549d0169ef8523")
  makeOutputPath "/gnu/store" "out" digest "jansson-2.15.0"
    @?= "/gnu/store/m6c1rmqg66pl0ff30fimv5lpqbx9cws6-jansson-2.15.0"
  storePathToName "/gnu/store" "/gnu/store/0123456789abcdfghijklmnpqrsvwxyz-name" @?= "name"
  forM_ [MD5, SHA1, SHA256, SHA512] $ \algorithm -> do
    let hash = hashBytes algorithm "abc"
    makeFixedOutputPath "/gnu/store" False algorithm hash "flat"
      @?= makeStorePath "/gnu/store" "output:out"
          (sha256 ("fixed:out:" <> algorithmName algorithm <> ":" <> encodeBase16 hash <> ":")) "flat"
  makeTextPath "/gnu/store" "text" "contents" ["/gnu/store/b", "/gnu/store/a"]
    @?= makeTextPath "/gnu/store" "text" "contents" ["/gnu/store/a", "/gnu/store/b"]

checkReferences :: IO ()
checkReferences = do
  let hashA = C.replicate 32 'a'
      hashB = C.replicate 32 'b'
      hashC = C.replicate 32 'c'
      a = "/gnu/store/" <> hashA <> "-a"
      b = "/gnu/store/" <> hashB <> "-b"
      sameHash = "/gnu/store/" <> hashA <> "-same"
      missing = "/gnu/store/" <> hashC <> "-missing"
      candidates = [a, b, sameHash, missing]
      contents = "prefix" <> hashA <> " middle " <> hashB <> " suffix"
      table = Map.fromListWith (++) [(referenceHash path, [path]) | path <- candidates]
  forM_ [1, 2, 3, 7, 8, 16, 31, 32, 33, 63, 64, 65, 127] $ \chunkSize -> do
    let chunks = splitEvery chunkSize contents
        (_, found) = scanChunks chunks table (B.empty, Set.empty)
    found @?= naiveReferences contents candidates
  let file = "hs1-reference-probe" :: B.ByteString
  writeRaw file contents
  (found, _) <- scanReferences file candidates
  found @?= Set.fromList [a, b, sameHash]
  let boundaryFile = "hs1-reference-boundary" :: B.ByteString
  writeRaw boundaryFile (B.replicate 65 0x20 <> hashA)
  (boundaryFound, _) <- scanReferences boundaryFile [a]
  boundaryFound @?= Set.singleton a
  removeLink boundaryFile
  removeLink file

splitEvery :: Int -> B.ByteString -> [B.ByteString]
splitEvery size bytes
  | B.null bytes = []
  | otherwise = let (chunk, rest) = B.splitAt size bytes in chunk : splitEvery size rest

writeRaw :: B.ByteString -> B.ByteString -> IO ()
writeRaw path bytes = bracket
  (openFd path WriteOnly defaultFileFlags { creat = Just 0o600, trunc = True }) closeFd $ \fd -> do
    written <- fdWrite fd bytes
    fromIntegral written @?= B.length bytes

(@?=) :: (Eq a, Show a) => a -> a -> IO ()
actual @?= expected = unless (actual == expected) (throwIO (userError ("expected " ++ show expected ++ ", got " ++ show actual)))
