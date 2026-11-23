{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Time the Haskell forward rewrite on ONE large regular file that holds no
-- occurrence of FROM.  The C++ side runs the same file through
-- checkRewriteForTest (nix/libstore/rewrite-speed-probe.cc).
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import System.CPUTime (getCPUTime)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.IO (hFlush, stdout)
import Text.Printf (printf)

import Goonix.Store.CaBuild (rewriteTree)

from, to :: B.ByteString
from = C.pack ("t" ++ take 30 (cycle "eout") ++ "t")
to = C.pack (take 32 (cycle "0123456789abcdfghijklmnpqrsvwxyz"))

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> d
        [] -> "/tmp/goonix-rewrite-speed"
      size = case args of
        (_:s:_) -> read s
        _ -> 8 * 1024 * 1024
  createDirectoryIfMissing True base
  let file = base ++ "/big"
  -- 'x' never appears in FROM: no occurrence, no rejection, so this measures
  -- the SEARCH cost the byte-by-byte loop pays.
  B.writeFile file (B.replicate size 0x78)
  start <- getCPUTime
  rewriteTree (C.pack file) from to
  end <- getCPUTime
  printf "HS_REWRITE_SECONDS %.3f bytes=%d\n"
    (fromIntegral (end - start) / (1e12 :: Double)) size
  hFlush stdout