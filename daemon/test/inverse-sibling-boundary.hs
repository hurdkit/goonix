{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Regression: inverseTree must invert a SIBLING hash wherever it appears,
-- including inside the streaming retention tail and across a 128 KiB read.
--
-- Before the fix the boundary retained only prefixes of `final`, so a sibling
-- hash ending within 31 bytes of the end of a file was split across chunks and
-- never replaced.  sameContent then said false for identical content, giving a
-- spurious CA collision for multi-output derivations - e.g. a wrapper whose
-- last line execs a sibling output's binary.
--
-- The expected digest is computed independently: rewrite the bytes in memory
-- (the same final->token and sibling-final->sibling-token substitutions) and
-- hash the canonical tree framing of the RESULT.  That is what inverseTree must
-- produce, wherever the match sits.
--
-- Fails before the fix, passes after.  Run: daemon/test/inverse-sibling-boundary.sh
module Main (main) where

import Control.Monad (forM)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Goonix.Store.Ca (put64, treeDomain)
import Goonix.Store.CaBuild (inverseTree)
import Goonix.Store.Base32 (encodeBase16)
import Goonix.Store.Hash (sha256)

-- | The whole-file substitution inverse() performs, applied in memory.
replace :: B.ByteString -> B.ByteString -> B.ByteString -> B.ByteString
replace from to = go
  where
    go bs
      | B.null from = bs
      | otherwise = case B.breakSubstring from bs of
          (before, rest)
            | B.null rest -> before
            | otherwise -> before <> to <> go (B.drop (B.length from) rest)

-- | Canonical tree framing of a regular file's bytes (C++ treeHash).
fileDigest :: B.ByteString -> B.ByteString
fileDigest contents =
  encodeBase16 (sha256 (treeDomain <> B.pack [1, 0]
    <> put64 (fromIntegral (B.length contents)) <> contents))

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/goonix-inverse-sibling-boundary"
      fin = C.pack (replicate 32 'f')
      tok = C.pack (replicate 32 't')
      sibFin = C.pack (replicate 32 's')
      sibTok = C.pack (replicate 32 'u')
      siblings = Map.fromList [(base <> "/" <> sibTok <> "-sib", base <> "/" <> sibFin <> "-sib")]
      -- The sibling hash at several distances from the end of the file, plus
      -- cases that straddle the 128 KiB read boundary.
      cases =
        [ ("tail-0", sibFin)
        , ("tail-1", sibFin <> "z")
        , ("tail-4", sibFin <> "-sib")
        , ("tail-30", sibFin <> C.pack (replicate 30 'z'))
        , ("tail-31", sibFin <> C.pack (replicate 31 'z'))
        , ("tail-40", sibFin <> C.pack (replicate 40 'z'))
        , ("wrapper-last-line", "#!/bin/sh\nexec " <> sibFin <> "/bin/prog\n")
        , ("read-boundary", C.pack (replicate (128 * 1024 - 16) 'x') <> sibFin <> "-sib")
        , ("read-boundary-exact", C.pack (replicate (128 * 1024 - 32) 'x') <> sibFin)
        , ("two-siblings-tail", sibFin <> " " <> sibFin)
        , ("final-and-sibling-tail", fin <> " " <> sibFin)
        ]
  createDirectoryIfMissing True (C.unpack base)
  results <- forM cases $ \(label, contents) -> do
    let path = base <> "/" <> label
    B.writeFile (C.unpack path) contents
    let expected = fileDigest (replace sibFin sibTok (replace fin tok contents))
    actual <- inverseTree path fin tok siblings
    if actual == expected
      then do
        putStrLn ("PASS " ++ C.unpack label)
        pure True
      else do
        putStrLn ("FAIL " ++ C.unpack label)
        hPutStrLn stderr ("  expected " ++ C.unpack expected)
        hPutStrLn stderr ("  actual   " ++ C.unpack actual)
        pure False
  let failed = length (filter not results)
  if failed == 0
    then putStrLn "INVERSE_SIBLING_BOUNDARY: PASS"
    else do
      putStrLn ("INVERSE_SIBLING_BOUNDARY: FAIL " ++ show failed ++ " case(s)")
      exitFailure