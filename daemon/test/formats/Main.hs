{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Main (main) where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import Goonix.Store.Base32
import Goonix.Store.Derivation
import Goonix.Store.Hash
import Goonix.Store.Nar
import Goonix.Store.Path
import System.Environment (getArgs)
import System.Directory (makeAbsolute)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [rootArg, mode] -> do
      root <- makeAbsolute rootArg
      run root mode
    [rootArg] -> do
      root <- makeAbsolute rootArg
      run root "all"
    _ -> hPutStrLn stderr "usage: formats VECTOR-DIRECTORY [sample]" >> exitFailure

run :: FilePath -> String -> IO ()
run root mode = case mode of
  "sample" -> do
    checkPrimitives
    checkSamples root
    checkDerivations root
    putStrLn "sample format checks passed"
  "all" -> do
    checkPrimitives
    checkNars root
    checkSamples root
    checkDerivations root
    putStrLn "format checks passed"
  _ -> hPutStrLn stderr "usage: formats VECTOR-DIRECTORY [sample]" >> exitFailure

checkPrimitives :: IO ()
checkPrimitives = do
  encodeBase16 (sha256 "abc") @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  encodeBase16 (sha256 "") @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  encodeBase16 (sha1 "abc") @?= "a9993e364706816aba3e25717850c26c9cd0d89d"
  encodeBase32 (sha256 "") @?= "0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73"
  encodeBase32 (sha256 "abc") @?= "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s"
  decodeBase32 (encodeBase32 (B.pack [0..63])) @?= Right (B.pack [0..63])
  decodeBase16 "A0ff" @?= Right (B.pack [0xa0,0xff])
  decodeBase32 "e" @?= Left "invalid base32 character"
  compressHash 3 (B.pack [1,2,3,4,5,6,7]) @?= B.pack [2,7,5]
  validateStoreName "hello-1.0" @?= Right ()
  validateStoreName ".hidden" @?= Left "invalid name: `.hidden' (can't begin with dot)"
  validateStoreName "bad/name" @?= Left "invalid character `/' in name `bad/name'"

checkNars :: FilePath -> IO ()
checkNars root = do
  hashes <- C.lines <$> B.readFile (root ++ "/nar-hashes.tsv")
  forM_ hashes $ \line -> case C.split '\t' line of
    [name, expected32, expected16, _] -> do
      actual <- hashNar ("/gnu/store/" <> name)
      encodeBase16 (hashDigest actual) @?= expected16
      encodeBase32 (hashDigest actual) @?= expected32
    _ -> throwIO (userError "malformed nar-hashes.tsv row")
checkSamples :: FilePath -> IO ()
checkSamples root = do
  samples <- C.lines <$> B.readFile (root ++ "/sample-manifest.tsv")
  forM_ samples $ \line -> case C.split '\t' line of
    [_, name, _] -> do
      expected <- B.readFile (root ++ "/nar/" ++ C.unpack name ++ ".nar")
      actual <- dumpNar ("/gnu/store/" <> name)
      unless (actual == expected) (throwIO (userError ("NAR bytes differ: " ++ C.unpack name)))
      case decodeNar actual of
        Left err -> throwIO (userError ("NAR decode failed for " ++ C.unpack name ++ ": " ++ err))
        Right parsed -> encodeNar parsed @?= actual
    _ -> throwIO (userError "malformed sample-manifest.tsv row")

checkDerivations :: FilePath -> IO ()
checkDerivations root = do
  fileNames <- lines <$> readFile (root ++ "/derivation-files")
  let files = if null fileNames
        then error "derivation-files is empty"
        else [root ++ "/derivations/" ++ reverse (takeWhile (/= '/') (reverse file)) | file <- fileNames]
  oracleLines <- C.lines <$> B.readFile (root ++ "/derivation-hashes.tsv")
  oracle <- Map.fromList <$> mapM parseOracleRow oracleLines
  let deferred = ["/gnu/store/5v89zslf5z04w4scb6fqmbl7wm45qflv-ca-probe.drv", "/gnu/store/wqb2pnxm8ksqgx626vpq7kwrkhy06cbw-ca-probe.drv"]
      isDeferred path drv = path `elem` deferred && Map.lookup "goonixAddressing" (environment drv) == Just "content"
  forM_ files $ \file -> do
    input <- B.readFile file
    let path = "/gnu/store/" <> C.pack (reverse (takeWhile (/= '/') (reverse file)))
    case (parseDerivation input, Map.lookup path oracle) of
      (Left err, _) -> throwIO (userError (file ++ ": " ++ err))
      (_, Nothing) -> throwIO (userError (file ++ ": missing modulo hash"))
      (Right drv, Just expectedHash) -> do
        writeDerivation drv @?= input
        if isDeferred path drv
          then putStrLn ("deferred HS-11 output paths: " ++ C.unpack path)
          else do
            let load inputPath = case Map.lookup inputPath oracle of
                  Nothing -> Left ("missing input hash: " ++ C.unpack inputPath)
                  Just digest -> Hash SHA256 <$> decodeBase16 digest
            case hashDerivationModulo drv load of
              Left err -> throwIO (userError (file ++ ": modulo hash: " ++ err))
              Right actual -> encodeBase16 (hashDigest actual) @?= expectedHash
            let expected = derivationOutputPaths "/gnu/store" path drv load
            case expected of
              Left err -> throwIO (userError (file ++ ": output paths: " ++ err))
              Right paths -> Map.map outputPath (outputs drv) @?= paths

(@?=) :: (Eq a, Show a) => a -> a -> IO ()
actual @?= expected = unless (actual == expected) (throwIO (userError ("expected " ++ show expected ++ ", got " ++ show actual)))

parseOracleRow :: ByteString -> IO (ByteString, ByteString)
parseOracleRow row = case C.split '\t' row of
  [path, digest] -> pure (path, digest)
  _ -> throwIO (userError "malformed derivation-hashes.tsv row")
