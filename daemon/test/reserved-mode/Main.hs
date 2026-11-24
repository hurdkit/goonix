{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell checkReservedTree with the SAME fixtures as the C++ probe
-- (nix/libstore/reserved-probe.cc).  daemon/test/reserved-mode.sh diffs them.
module Main (main) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString.Char8 as C
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stdout)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Files.ByteString as Files

import Goonix.Store.CaBuild (checkReservedTree)

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-reserved-hs"
      token = C.pack ("e" ++ replicate 31 't')
      placeholder = token <> "-name"
      mkdir p = createDirectoryIfMissing True (C.unpack p)
      report :: String -> RawFilePath -> IO ()
      report label dir = do
        r <- try (checkReservedTree dir 0 "")
        let outcome = case r of
              Right () -> "ok"
              Left (_ :: SomeException) -> "threw"
        hPutStrLn stdout (label ++ " " ++ outcome)

  let whole = base <> "/whole"
  mkdir whole
  C.writeFile (C.unpack (whole <> "/f")) ("prefix" <> placeholder <> "suffix")
  report "whole-chunk" whole

  mapM_ (\split -> do
    let d = base <> "/split" <> C.pack (show (split :: Int))
    mkdir d
    C.writeFile (C.unpack (d <> "/f"))
      (C.pack (replicate (128 * 1024 - split) 'x') <> placeholder)
    report ("split-" ++ show split) d) [1, 16, 31, 32, 33]

  let nm = base <> "/name"
  mkdir nm
  C.writeFile (C.unpack (nm <> "/" <> placeholder)) "x"
  report "in-name" nm

  let lk = base <> "/link"
  mkdir lk
  Files.createSymbolicLink ("/gnu/store/" <> placeholder) (lk <> "/l")
  report "in-symlink" lk

  let nd = base <> "/no-dash"
  mkdir nd
  C.writeFile (C.unpack (nd <> "/f")) (token <> "x")
  report "no-dash" nd

  let nk = base <> "/nuke"
  mkdir nk
  C.writeFile (C.unpack (nk <> "/f")) (C.pack (replicate 32 'e') <> "-name")
  report "nuke-marker" nk

  let b32 = base <> "/base32"
  mkdir b32
  C.writeFile (C.unpack (b32 <> "/f")) (C.pack (replicate 32 'a') <> "-name")
  report "base32-hash" b32