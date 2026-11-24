{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell addIndirectRoot with the SAME fixtures as the C++ probe
-- (nix/libstore/gcroot-probe.cc).  daemon/test/gcroot-mode.sh diffs them.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (filterM)
import qualified Data.ByteString.Char8 as C
import Data.List (sort, intercalate, isInfixOf)
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.FilePath (takeFileName)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stdout)
import qualified System.Posix.Files.ByteString as Files

import Goonix.Store.ReadOnly (openStore, closeStore)
import Goonix.Store.Writing (addIndirectRoot)

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-gcroot-hs"
      storeDir = base <> "/store"
      stateDir = base <> "/state"
      -- The root NAME is SHA1 of the target PATH: both lanes must name the SAME
      -- path string (2nd arg) or the names cannot be compared.  The files live
      -- in this lane's own scratch store.
      namedStore = case args of
        (_:s:_) -> C.pack s
        _ -> base <> "/store"
      target = namedStore <> "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-item"
      targetFile = storeDir <> "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-item"
      other = namedStore <> "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other"
      otherFile = storeDir <> "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other"
      autoDir = stateDir <> "/gcroots/auto"
      mkdir p = createDirectoryIfMissing True (C.unpack p)
  mkdir storeDir; mkdir stateDir
  C.writeFile (C.unpack targetFile) "x"
  C.writeFile (C.unpack otherFile) "y"
  store <- openStore storeDir (C.unpack (stateDir <> "/db.sqlite")) stateDir
  let listRoots = do
        present <- Files.fileExist autoDir
        if not present then pure "" else do
          ns <- listDirectory (C.unpack autoDir)
          pure (intercalate "," (sort ns))
      outcomeOf (Right ()) = "ok"
      outcomeOf (Left e) = "threw: " ++ show (e :: SomeException)

  r1 <- try (addIndirectRoot store target)
  names <- listRoots
  resolved <- if null names then pure "" else
    C.unpack <$> Files.readSymbolicLink (autoDir <> "/" <> C.pack names)
  hPutStrLn stdout ("root-name " ++ names ++ " target-match="
    ++ (if resolved == C.unpack target then "1" else "0") ++ " " ++ outcomeOf r1)

  r2 <- try (addIndirectRoot store target)
  n2 <- listRoots
  hPutStrLn stdout ("root-idempotent " ++ n2 ++ " " ++ outcomeOf r2)

  r3 <- try (addIndirectRoot store other)
  n3 <- listRoots
  hPutStrLn stdout ("two-roots " ++ n3 ++ " " ++ outcomeOf r3)

  -- 4. A STALE TEMPORARY at the fixed .tmp-goonix name must not block the
  --    replace (C++ uses .tmp-PID-RAND and never collides with it).  The root
  --    is found by RESOLVING the listing, not by recomputing the name, so the
  --    probe does not reimplement the naming it is checking.
  let rootNamed n = autoDir <> "/" <> C.pack n
      rootPointingAt want = do
        ns <- listRoots
        let candidates = filter (not . null) (splitOn ',' ns)
        hits <- filterM (\n -> (== want) . C.pack <$> readLinkOrEmpty (rootNamed n)) candidates
        pure (case hits of
                (n:_) -> rootNamed n
                [] -> autoDir <> "/missing")
  rootTarget <- rootPointingAt target
  C.writeFile (C.unpack (rootTarget <> ".tmp-goonix")) "stale"
  r4 <- try (addIndirectRoot store target)
  resolved4 <- readLinkOrEmpty rootTarget
  hPutStrLn stdout ("stale-temp target-match="
    ++ (if resolved4 == C.unpack target then "1" else "0") ++ " " ++ outcomeOf r4)

  -- 5. Re-pointing the OTHER existing root still resolves to its target.
  rootOther <- rootPointingAt other
  r5 <- try (addIndirectRoot store other)
  resolved5 <- readLinkOrEmpty rootOther
  hPutStrLn stdout ("repoint target-match="
    ++ (if resolved5 == C.unpack other then "1" else "0") ++ " " ++ outcomeOf r5)

  -- 6. Neither side may touch a FOREIGN stale temp, and neither may leave a
  --    temp of its own.  With per-call temp names the planted .tmp-goonix
  --    survives untouched on BOTH sides, so no exclusion is needed.
  entries <- listDirectory (C.unpack autoDir)
  let planted = takeFileName (C.unpack rootTarget) ++ ".tmp-goonix"
      foreignKept = length (filter (== planted) entries)
      ownTemps = length (filter (\n -> isInfixOf ".tmp" n && n /= planted) entries)
  hPutStrLn stdout ("foreign-temp-kept count=" ++ show foreignKept)
  hPutStrLn stdout ("no-leftover-temp count=" ++ show ownTemps)
  closeStore store

-- Read a symlink's target, or "" when it is absent (the C++ probe catches and
-- reports an empty string the same way).
readLinkOrEmpty :: C.ByteString -> IO String
readLinkOrEmpty p = do
  r <- try (Files.readSymbolicLink p)
  pure $ case r of
    Right t -> C.unpack t
    Left (_ :: SomeException) -> ""

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, []) -> [a]
  (a, _:rest) -> a : splitOn c rest
