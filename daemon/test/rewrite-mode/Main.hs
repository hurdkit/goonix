{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell rewriteTree mode handling with the SAME fixtures as the
-- C++ probe (nix/libstore/rewrite-mode-probe.cc), so the two can be compared
-- line by line.  Prints mode-before, mode-after and the outcome per input mode.
--
-- Build and run with daemon/test/rewrite-mode.sh.
module Main (main) where

import Control.Exception (SomeException, try)
import Data.Bits ((.&.))
import qualified Data.ByteString.Char8 as C
import Data.List (sort)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Posix.Types (FileMode)
import System.Posix.Files.ByteString (setFileMode)
import qualified System.Posix.Files.ByteString as Files
import System.IO (hPutStrLn, stdout)
import Text.Printf (printf)

import Goonix.Store.CaBuild (rewriteTree)

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> d
        [] -> "/tmp/ca-mode-hs"
      token = C.pack (replicate 32 't')
      replacement = C.pack (replicate 32 'u')
      modes :: [FileMode]
      modes = [0o200, 0o222, 0o000, 0o644, 0o444, 0o755, 0o555, 0o600]
  mapM_ (probe base token replacement) modes
  hardlinkTwin base token replacement
  refusedOriginal base token
  where
    probe base token replacement m = do
      let dir = C.pack base <> "/m" <> C.pack (show (fromIntegral m :: Int))
          file = dir <> "/payload"
      createDirectoryIfMissing True (C.unpack dir)
      C.writeFile (C.unpack file) (C.pack ("/gnu/store/" <> C.unpack token <> "-x/data\n"))
      setFileMode file m
      before <- Files.fileMode <$> Files.getSymbolicLinkStatus file
      outcome <- try (rewriteTree dir token replacement)
      let message = case outcome of
            Right () -> "ok"
            Left e -> "threw: " ++ show (e :: SomeException)
      present <- Files.fileExist file
      after <- if present
        then Files.fileMode <$> Files.getSymbolicLinkStatus file
        else pure 0
      setFileMode dir 0o755
      if present then setFileMode file 0o644 else pure ()
      hPutStrLn stdout (printf "mode=%04o before=%04o after=%04o present=%d %s"
        (fromIntegral m :: Int) (fromIntegral (before .&. 0o7777) :: Int) (fromIntegral (after .&. 0o7777) :: Int)
        (if present then 1 else 0 :: Int) message)

-- | A hard-linked twin OUTSIDE the rewritten tree keeps the ORIGINAL inode, so
-- it keeps whatever mode the rewrite left on that inode.  C++ only adds
-- S_IRUSR when missing; chmod 0600 would strip the twin's executable bit.
hardlinkTwin :: String -> C.ByteString -> C.ByteString -> IO ()
hardlinkTwin base token replacement = do
  let dir = C.pack base <> "/hardlink"
      outside = C.pack base <> "/outside"
      file = dir <> "/payload"
      twin = outside <> "/twin"
  createDirectoryIfMissing True (C.unpack dir)
  createDirectoryIfMissing True (C.unpack outside)
  C.writeFile (C.unpack file) (C.pack ("/gnu/store/" <> C.unpack token <> "-x/data\n"))
  setFileMode file 0o555
  Files.createLink file twin
  outcome <- try (rewriteTree dir token replacement)
  let message :: String = case outcome of
        Right () -> "ok"
        Left e -> "threw: " ++ show (e :: SomeException)
  t <- Files.fileMode <$> Files.getSymbolicLinkStatus twin
  setFileMode dir 0o755
  setFileMode outside 0o755
  setFileMode file 0o644
  setFileMode twin 0o644
  hPutStrLn stdout (printf "hardlink-twin after=%04o %s"
    (fromIntegral (t .&. 0o7777) :: Int) message)

-- | The FAILURE path: an opaque fragment makes the rewrite throw.  The original
-- file must be left as C++ leaves it - readable, no bit cleared - not 0600.
refusedOriginal :: String -> C.ByteString -> IO ()
refusedOriginal base token = do
  let dir = C.pack base <> "/refused"
      file = dir <> "/payload"
      contents = C.pack (replicate (128 * 1024 - 31) 'x')
                 <> C.take 1 token <> C.take 7 (C.drop 1 token) <> "tail"
  createDirectoryIfMissing True (C.unpack dir)
  C.writeFile (C.unpack file) contents
  setFileMode file 0o555
  outcome <- try (rewriteTree dir token token)
  let message :: String = case outcome of
        Right () -> "ok"
        Left (_ :: SomeException) -> "threw"
  a <- Files.fileMode <$> Files.getSymbolicLinkStatus file
  setFileMode dir 0o755
  setFileMode file 0o644
  hPutStrLn stdout (printf "refused-original after=%04o %s"
    (fromIntegral (a .&. 0o7777) :: Int) message)