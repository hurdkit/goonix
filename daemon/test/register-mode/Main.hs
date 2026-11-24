{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell registerPath with the SAME fixtures as the C++ probe
-- (nix/libstore/register-probe.cc, which calls LocalStore::registerValidPath).
-- daemon/test/register-mode.sh diffs the two.
module Main (main) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString.Char8 as C
import qualified Data.Set as Set
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stdout)
import System.Posix.ByteString (RawFilePath)
import Text.Printf (printf)

import Goonix.Store.Database (Value (..), queryValues)
import Goonix.Store.Hash (Hash (..), HashAlgorithm (..), sha256)
import Goonix.Store.ReadOnly (Store (..), openStore, closeStore, isValidPath)
import Goonix.Store.Writing (registerPath)

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-register-hs"
      storeDir = base <> "/store"
      stateDir = base <> "/state"
      a = storeDir <> "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a"
      b = storeDir <> "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b"
      missing = storeDir <> "/cccccccccccccccccccccccccccccccc-missing"
      z = storeDir <> "/dddddddddddddddddddddddddddddddd-zero"
      mkdir p = createDirectoryIfMissing True (C.unpack p)
  mkdir storeDir; mkdir stateDir
  C.writeFile (C.unpack a) "aaa"
  C.writeFile (C.unpack b) "bbb"
  C.writeFile (C.unpack z) ""
  store <- openStore storeDir (C.unpack (stateDir <> "/db.sqlite")) stateDir
  let report :: String -> IO () -> IO ()
      report label action = do
        r <- try action
        let outcome = case r of
              Right () -> "ok"
              Left e -> "threw: " ++ show (e :: SomeException)
        valid <- isValidPath store a
        hPutStrLn stdout (printf "%s valid=%d %s" label (if valid then 1 else 0 :: Int) outcome)
      narSizeOf :: RawFilePath -> IO String
      narSizeOf p = do
        rows <- queryValues (database store)
          "select narSize from ValidPaths where path = ?;" [Bytes p]
        pure $ case rows of
          [[Integer n]] -> show n
          [[Null]] -> "0"
          _ -> "missing"
      refCountOf p = do
        rows <- queryValues (database store)
          "select count(*) from Refs where referrer = (select id from ValidPaths where path = ?);"
          [Bytes p]
        pure $ case rows of
          [[Integer n]] -> show n
          _ -> "missing"

  -- 1. A self-reference is registered and kept.
  report "self-reference" (registerPath store a (Hash SHA256 (sha256 "aaa")) 3 [a] "")
  rc <- refCountOf a
  hPutStrLn stdout ("self-reference-kept count=" ++ rc)

  -- 2. Re-registering the same path updates the row.
  report "re-register-updates" (registerPath store a (Hash SHA256 (sha256 "zzz")) 99 [a] "")
  ns <- narSizeOf a
  hPutStrLn stdout ("re-register-narsize " ++ ns)

  -- 3. A reference to an unregistered path is refused.
  report "unknown-reference" (registerPath store b (Hash SHA256 (sha256 "bbb")) 3 [missing] "")

  -- 4. narSize 0 is stored as NULL.
  r4 <- try (registerPath store z (Hash SHA256 (sha256 "")) 0 [] "")
  let o4 = case r4 of
        Right () -> "ok"
        Left e -> "threw: " ++ show (e :: SomeException)
  zn <- narSizeOf z
  hPutStrLn stdout ("zero-narsize " ++ zn ++ " " ++ o4)
  closeStore store