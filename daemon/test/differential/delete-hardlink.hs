{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- Regression: deleteTree must NOT chmod the file it unlinks.  A store file is
-- deduplicated by hard-linking it into .links, so several store paths share one
-- inode.  The GC deletes a dead path (or its .links entry) with deleteTree while a
-- concurrent build execs another link to the same inode (the bootstrap bash
-- builder).  If deleteTree chmods the file to 0o644 before unlinking — as it did
-- before the fix — it strips the exec bit from the SHARED inode, and the build's
-- sandbox exec fails EACCES ("executing ...bash: Permission denied").  C++
-- _deletePathAt (util.cc) only makes DIRECTORIES writable to recurse, then
-- unlinkat; it never chmods the file, because unlink needs write permission on the
-- parent directory, not on the file.
--
-- This probe calls the daemon's OWN deleteTree on one hard link and checks the
-- other link's mode is unchanged.  FAILS on the pre-fix tree (exec bit stripped),
-- PASSES after.  No daemon, store fixture, or namespace is needed.
module Main (main) where

import Control.Exception (catch)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Goonix.Store.Files (deleteTree)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import System.Posix.Files.ByteString (createLink, fileMode, getSymbolicLinkStatus, setFileMode)

main :: IO ()
main = do
  tmp <- C.pack <$> getTemporaryDirectory
  let dir = tmp <> "/goonix-delete-hardlink"
  removeDirectoryRecursive (C.unpack dir) `catch` (\(_ :: IOError) -> pure ())
  createDirectoryIfMissing True (C.unpack dir)
  createDirectoryIfMissing True (C.unpack (dir <> "/.links"))
  createDirectoryIfMissing True (C.unpack (dir <> "/store"))
  -- An executable store file (mode 0555, like a deduplicated builder).
  let bash = dir <> "/store/bash"
      link = dir <> "/.links/bash-dedup"
  B.writeFile (C.unpack bash) "#!/bin/sh\necho hi\n"
  setFileMode bash 0o555
  createLink bash link              -- dedup: same inode, two directory entries
  before <- fileMode <$> getSymbolicLinkStatus bash
  -- The GC deletes the .links entry (a different link to the SAME inode).
  deleteTree link
  after <- fileMode <$> getSymbolicLinkStatus bash
  removeDirectoryRecursive (C.unpack dir) `catch` (\(_ :: IOError) -> pure ())
  if after == before
    then do
      putStrLn "DELETE_HARDLINK_PASS (deleteTree left the shared inode's mode unchanged)"
      exitSuccess
    else do
      hPutStrLn stderr ("DELETE_HARDLINK_FAIL: deleteTree changed the shared inode mode from "
                        ++ showOct before ++ " to " ++ showOct after
                        ++ " - a concurrent exec of the other link would get EACCES")
      exitFailure

showOct :: Integral a => a -> String
showOct m = "0o" ++ oct (fromIntegral m)
  where
    oct 0 = "0"
    oct n = oct (n `div` 8) ++ show (n `mod` 8)