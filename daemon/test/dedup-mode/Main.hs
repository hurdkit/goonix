{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell deduplicateTree (.links pool) with the SAME fixtures as
-- the C++ probe (nix/libstore/dedup-probe.cc, which calls
-- LocalStore::optimisePath).  daemon/test/dedup-mode.sh diffs the two.
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

import Goonix.Store.Files (deduplicateTree)

modeOf :: RawFilePath -> IO Int
modeOf p = do
  present <- Files.fileExist p
  if not present then pure 0xFFFF else do
    m <- Files.fileMode <$> Files.getSymbolicLinkStatus p
    pure (fromIntegral (m .&. 0o7777))

linksOf :: RawFilePath -> IO Int
linksOf p = do
  present <- Files.fileExist p
  if not present then pure 0xFFFF
    else fromIntegral . Files.linkCount <$> Files.getSymbolicLinkStatus p

inodeOf :: RawFilePath -> IO Integer
inodeOf p = do
  present <- Files.fileExist p
  if not present then pure 0
    else fromIntegral . Files.fileID <$> Files.getSymbolicLinkStatus p

outcomeOf :: Either SomeException () -> String
outcomeOf (Right ()) = "ok"
outcomeOf (Left e) = "threw: " ++ show e

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-dedup-hs"
      store = base <> "/store"
      big = C.pack (replicate 9000 'a')
      small = C.pack (replicate 100 'a')
      item n = store <> "/" <> C.pack (replicate 32 n) <> "-item-" <> C.pack [n]
      mk n contents mode = do
        let d = item n
        createDirectoryIfMissing True (C.unpack d)
        C.writeFile (C.unpack (d <> "/f")) contents
        Files.setFileMode (d <> "/f") mode
        Files.setFileMode d 0o555
        pure d
  createDirectoryIfMissing True (C.unpack store)
  Files.setFileMode store 0o755
  createDirectoryIfMissing True (C.unpack (store <> "/.links"))

  -- 1. Two identical large files in different items: the second becomes a
  --    hard link of the first; directory modes restored.
  a <- mk 'a' big 0o444
  b <- mk 'b' big 0o444
  r1 <- try (deduplicateTree store (a <> "/f") >> deduplicateTree store (b <> "/f"))
  same <- (==) <$> inodeOf (a <> "/f") <*> inodeOf (b <> "/f")
  bm <- modeOf (b <> "/f"); bd <- modeOf b; bn <- linksOf (b <> "/f")
  hPutStrLn stdout (printf "dedup-pair same-inode=%d b-mode=%04o b-dir=%04o b-nlink=%d %s"
    (if same then 1 else 0 :: Int) bm bd bn (outcomeOf r1))
  Files.setFileMode a 0o755; Files.setFileMode b 0o755

  -- 2. A WRITABLE file is skipped, not linked and not chmod'd.
  c <- mk 'c' big 0o644
  r2 <- try (deduplicateTree store (c <> "/f"))
  cm <- modeOf (c <> "/f"); cn <- linksOf (c <> "/f")
  hPutStrLn stdout (printf "writable-skip mode=%04o nlink=%d %s" cm cn (outcomeOf r2))
  Files.setFileMode c 0o755

  -- 3. Below the size threshold: skipped entirely.
  d <- mk 'd' small 0o444
  r3 <- try (deduplicateTree store (d <> "/f"))
  dn <- linksOf (d <> "/f")
  hPutStrLn stdout (printf "below-threshold nlink=%d %s" dn (outcomeOf r3))
  Files.setFileMode d 0o755

  -- 4. An EXECUTABLE large file must not link with the non-executable payload.
  e <- mk 'e' big 0o555
  r4 <- try (deduplicateTree store (e <> "/f"))
  distinct <- (/=) <$> inodeOf (e <> "/f") <*> inodeOf (a <> "/f")
  em <- modeOf (e <> "/f")
  hPutStrLn stdout (printf "exec-not-linked distinct-inode=%d mode=%04o %s"
    (if distinct then 1 else 0 :: Int) em (outcomeOf r4))
  Files.setFileMode e 0o755

  -- 5. A different payload gets its own .links entry.
  f <- mk 'f' (C.pack (replicate 9000 'z')) 0o444
  r5 <- try (deduplicateTree store (f <> "/f"))
  fn <- linksOf (f <> "/f")
  hPutStrLn stdout (printf "fresh-hash nlink=%d %s" fn (outcomeOf r5))
  Files.setFileMode f 0o755