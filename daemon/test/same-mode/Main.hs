{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell sameContent VERDICT with the SAME fixtures as the C++
-- probe (nix/libstore/same-probe.cc).  inverseTree is probed separately; what
-- sameContent adds is the hash-part extraction from the final/token paths and
-- the equality against printHash expected.  daemon/test/same-mode.sh diffs them.
module Main (main) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stdout)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Files.ByteString as Files

import Goonix.Store.Base32 (decodeBase16)
import Goonix.Store.Ca (put64, treeDomain)
import Goonix.Store.CaBuild (inverseTree, sameContent)
import Goonix.Store.Hash (Hash (..), HashAlgorithm (..), sha256)

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-same-hs"
      fin = C.pack (replicate 32 'f')
      tok = C.pack (replicate 32 't')
      none = Map.empty
      mkdir p = createDirectoryIfMissing True (C.unpack p)
      put p contents = do
        mkdir (C.dropWhileEnd (/= '/') p)
        C.writeFile (C.unpack p) contents
      fixture label = do
        let store = base <> "/" <> label
        mkdir store
        pure store
      named store hash name = store <> "/" <> hash <> "-" <> name
      parseHex h = case decodeBase16 h of
        Right d -> Hash SHA256 d
        Left e -> error e
      report :: String -> RawFilePath -> RawFilePath -> RawFilePath -> Hash
        -> Map.Map C.ByteString C.ByteString -> IO ()
      report label p finalP tokenP expected sib = do
        r <- try (sameContent p finalP tokenP expected sib)
        let text = case r of
              Left (e :: SomeException) -> "threw: " <> C.pack (show e)
              Right True -> "true"
              Right False -> "false"
        hPutStrLn stdout (label ++ " " ++ C.unpack text)
      expectedOf p sib = do
        digest <- inverseTree p fin tok sib
        pure (parseHex digest)

  -- 1. A plain file whose inverse digest IS the expected hash: true.
  do s <- fixture "f1"
     let d = named s fin "item"
     put (d <> "/f") "hello"
     e <- expectedOf (d <> "/f") none
     report "match" (d <> "/f") d (named s tok "item") e none

  -- 2. A DIFFERENT expected hash: must be false.
  do s <- fixture "f2"
     let d = named s fin "item"
     put (d <> "/f") "hello"
     report "mismatch" (d <> "/f") d (named s tok "item")
       (parseHex (C.pack (replicate 64 '0'))) none

  -- 3. The tree CONTAINS the token: the expected hash is the inverse digest.
  do s <- fixture "f3"
     let d = named s fin "item"
     put (d <> "/self") (named s tok "item")
     e <- expectedOf (d <> "/self") none
     report "token-in-tree" (d <> "/self") d (named s tok "item") e none

  -- 4. Expected hash WITHOUT the inverse mapping: must be false.  inverseTree
  --    maps FINAL -> TOKEN, so the tree must hold the FINAL hash for the
  --    mapping to change anything (holding the token made it vacuous).
  do s <- fixture "f4"
     let d = named s fin "item"
     put (d <> "/self") (named s fin "item")
     raw <- inverseTree (d <> "/self") tok tok none
     report "no-inverse-mismatch" (d <> "/self") d (named s tok "item")
       (parseHex raw) none

  -- 5. The hash part comes from the BASENAME, not the whole path.
  do s <- fixture "f5"
     let d = named s fin "item"
         deep = s <> "/nested/deep/" <> fin <> "-item"
     put (d <> "/f") "hello"
     e <- expectedOf (d <> "/f") none
     report "basename-extraction" (d <> "/f") deep (named s tok "item") e none

  -- 6. A final path shorter than 32 characters after the store prefix.
  do s <- fixture "f6"
     let d = named s fin "item"
     put (d <> "/f") "hello"
     e <- expectedOf (d <> "/f") none
     report "short-final" (d <> "/f") (s <> "/short") (named s tok "item") e none

  -- 7. Siblings: the map reverses sibling finals back to tokens.  The sibling
  --    hash must clear the 31-byte retention tail: the boundary loop protects
  --    only prefixes of FINAL, so a sibling hash in the tail never matches.
  --    Measured: 0/1 trailing bytes -> no effect; 31/32/40 -> reversal applies.
  do s <- fixture "f7"
     let d = named s fin "item"
         sibFinal = named s (C.pack (replicate 32 's')) "sib"
         sibToken = named s (C.pack (replicate 32 'u')) "sib"
         sib = Map.fromList [(sibToken, sibFinal)]
     put (d <> "/uses-sib") (sibFinal <> C.pack (replicate 40 (toEnum 122)))
     e <- expectedOf (d <> "/uses-sib") sib
     report "siblings" (d <> "/uses-sib") d (named s tok "item") e sib

  -- 8. Expected digest computed WITHOUT the sibling map: must be false.
  do s <- fixture "f8"
     let d = named s fin "item"
         sibFinal = named s (C.pack (replicate 32 's')) "sib"
         sibToken = named s (C.pack (replicate 32 'u')) "sib"
         sib = Map.fromList [(sibToken, sibFinal)]
     put (d <> "/uses-sib") (sibFinal <> C.pack (replicate 40 (toEnum 122)))
     e <- expectedOf (d <> "/uses-sib") none
     report "siblings-unapplied" (d <> "/uses-sib") d (named s tok "item") e sib

  -- 8b. The sibling hash INSIDE the retention tail: it MUST still be inverted.
  --     This asserts the CORRECT result, not the old limitation.  The
  --     expectation is computed INDEPENDENTLY (substitute in memory, then frame
  --     and hash) rather than through inverseTree, which shared the boundary
  --     bug and would otherwise agree with the broken output.  Until the C++
  --     inverseTree fix lands on goonix-implementation, C++ reports false here
  --     and the fixed Haskell side true, so the probe DIFFERS - expected
  --     (reviewer, 2026-11-23).
  do s <- fixture "f8b"
     let d = named s fin "item"
         sibFin = C.pack (replicate 32 's')
         sibTok = C.pack (replicate 32 'u')
         sibFinal = named s sibFin "sib"
         sibToken = named s sibTok "sib"
         sib = Map.fromList [(sibToken, sibFinal)]
         substitute from to = go
           where go bs = case C.breakSubstring from bs of
                   (before, rest)
                     | B.null rest -> before
                     | otherwise -> before <> to <> go (B.drop (B.length from) rest)
         substituted = substitute sibFin sibTok sibFinal
         framed = treeDomain <> B.pack [1, 0]
           <> put64 (fromIntegral (B.length substituted)) <> substituted
         e = Hash SHA256 (sha256 framed)
     put (d <> "/uses-sib") sibFinal
     report "sibling-in-tail" (d <> "/uses-sib") d (named s tok "item") e sib

  -- 9. An executable file: the execute bit is part of the NAR.
  do s <- fixture "f9"
     let d = named s fin "item"
         plain = named s (C.pack (replicate 32 'p')) "plain"
     put (d <> "/x") "script"
     put (plain <> "/x") "script"
     Files.setFileMode (plain <> "/x") 0o444
     Files.setFileMode (d <> "/x") 0o555
     e <- expectedOf (plain <> "/x") none
     report "exec-bit" (d <> "/x") d (named s tok "item") e none

  -- 10. A missing path: must refuse rather than return true.
  do s <- fixture "f10"
     let d = named s fin "item"
     mkdir d
     report "missing" (d <> "/absent") d (named s tok "item")
       (parseHex (C.pack (replicate 64 '0'))) none
