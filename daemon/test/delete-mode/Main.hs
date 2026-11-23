{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell deleteTree with the SAME fixtures as the C++ probe
-- (nix/libstore/delete-probe.cc, which calls deletePath).
-- daemon/test/delete-mode.sh diffs the two.
module Main (main) where

import Control.Exception (SomeException, try)
import Data.Bits ((.&.))
import qualified Data.ByteString.Char8 as C
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stdout)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Files.ByteString as Files
import Text.Printf (printf)

import Goonix.Store.Files (deleteTree)

modeOf :: RawFilePath -> IO Int
modeOf p = do
  st <- try (Files.getSymbolicLinkStatus p)
  case st of
    Left (_ :: SomeException) -> pure 0xFFFF
    Right s -> pure (fromIntegral (Files.fileMode s .&. 0o7777))

linksOf :: RawFilePath -> IO Int
linksOf p = do
  st <- try (Files.getSymbolicLinkStatus p)
  case st of
    Left (_ :: SomeException) -> pure 0xFFFF
    Right s -> pure (fromIntegral (Files.linkCount s))

exists :: RawFilePath -> IO Bool
exists p = do
  st <- try (Files.getSymbolicLinkStatus p)
  pure $ case st of
    Left (_ :: SomeException) -> False
    Right _ -> True

outcomeOf :: Either SomeException () -> String
outcomeOf (Right ()) = "ok"
outcomeOf (Left e) = "threw: " ++ show e

gone :: RawFilePath -> IO Int
gone p = do { e <- exists p; pure (if e then 0 else 1) }

alive :: RawFilePath -> IO Int
alive p = do { e <- exists p; pure (if e then 1 else 0) }

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-delete-hs"
      mkdir p = createDirectoryIfMissing True (C.unpack p)

  -- 1. Hard-linked twin outside the deleted tree keeps its MODE.
  let tree1 = base <> "/tree1"; outside1 = base <> "/outside1"
  mkdir tree1; mkdir outside1
  let f1 = tree1 <> "/f"; twin1 = outside1 <> "/twin"
  C.writeFile (C.unpack f1) (C.pack (replicate 9000 'a'))
  Files.setFileMode f1 0o555
  Files.createLink f1 twin1
  Files.setFileMode tree1 0o555
  Files.setFileMode outside1 0o555
  r1 <- try (deleteTree tree1)
  tm1 <- modeOf twin1; tn1 <- linksOf twin1; g1 <- gone tree1
  hPutStrLn stdout (printf "delete-hardlink twin-mode=%04o twin-nlink=%d tree-gone=%d %s"
    tm1 tn1 g1 (outcomeOf r1))
  Files.setFileMode outside1 0o755

  -- 2. A read-only PARENT: what mode is it left in?
  let parent2 = base <> "/parent2"
  mkdir parent2
  let f2 = parent2 <> "/f"
  C.writeFile (C.unpack f2) "x"
  Files.setFileMode f2 0o444
  Files.setFileMode parent2 0o555
  r2 <- try (deleteTree f2)
  pm2 <- modeOf parent2; g2 <- gone f2
  hPutStrLn stdout (printf "delete-readonly-parent parent-mode=%04o file-gone=%d %s"
    pm2 g2 (outcomeOf r2))
  Files.setFileMode parent2 0o755

  -- 3. Nested read-only directories, twin outside.
  let tree3 = base <> "/tree3"; outside3 = base <> "/outside3"
  mkdir (tree3 <> "/sub"); mkdir outside3
  let f3 = tree3 <> "/sub/f"; twin3 = outside3 <> "/twin"
  C.writeFile (C.unpack f3) (C.pack (replicate 9000 'b'))
  Files.setFileMode f3 0o444
  Files.createLink f3 twin3
  Files.setFileMode (tree3 <> "/sub") 0o555
  Files.setFileMode tree3 0o555
  Files.setFileMode outside3 0o555
  r3 <- try (deleteTree tree3)
  tm3 <- modeOf twin3; tn3 <- linksOf twin3; g3 <- gone tree3
  hPutStrLn stdout (printf "delete-nested twin-mode=%04o twin-nlink=%d tree-gone=%d %s"
    tm3 tn3 g3 (outcomeOf r3))
  Files.setFileMode outside3 0o755

  -- 4. Deleting a symlink must not follow it.
  let tree4 = base <> "/tree4"; outside4 = base <> "/outside4"
  mkdir tree4; mkdir outside4
  let target4 = outside4 <> "/target"
  C.writeFile (C.unpack target4) (C.pack (replicate 9000 'c'))
  Files.setFileMode target4 0o555
  Files.createSymbolicLink target4 (tree4 <> "/link")
  Files.setFileMode tree4 0o555
  Files.setFileMode outside4 0o555
  r4 <- try (deleteTree tree4)
  tm4 <- modeOf target4; a4 <- alive target4; g4 <- gone tree4
  hPutStrLn stdout (printf "delete-symlink target-mode=%04o target-alive=%d tree-gone=%d %s"
    tm4 a4 g4 (outcomeOf r4))
  Files.setFileMode outside4 0o755