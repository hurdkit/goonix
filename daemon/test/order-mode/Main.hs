{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell contentOutputOrder with the SAME fixtures as the C++
-- probe (nix/libstore/order-probe.cc).  Compares the emitted ORDER itself.
-- daemon/test/order-mode.sh diffs them.
module Main (main) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stdout)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Files.ByteString as Files

import Goonix.Store.CaBuild (contentOutputOrder)
import Goonix.Store.Derivation (Derivation (..), DerivationOutput (..))

-- REAL base32 store paths, not reserved tokens: scanReferences rejects every
-- byte outside nix's base32 alphabet and the reserved token alphabet is not it,
-- so token fixtures create NO reference edge at all.  The hash parts are
-- independent per output: a repeated character matches itself at every offset,
-- and a rotation of one string contains the others' prefixes, either of which
-- invents edges that are not there.
hashFor :: C.ByteString -> C.ByteString
hashFor name = case name of
  "out" -> "8sf4wnjhhjnw4fs8qaylc620026clyaq"
  "lib" -> "9vg5xpkiikpx5gv9rbzmd731137dmzbr"
  "dev" -> "1k7xmgb99bgmx7k1i3pd5zvrrvz5dp3i"
  "aaa" -> "xg3rib7557bir3gxdzk91vpmmpv19kzd"
  "bbb" -> "sc0nf842248fn0csawh6yqljjlqy6hwa"
  "ccc" -> "p9xkb51zz15bkx9p7rd3vmiggimv3dr7"
  "zzz" -> "j4qf60wssw06fq4j2l8ynhcaachny8l2"
  "other" -> "yh4sjc8668cjs4hyf0la2wqnnqw2al0f"
  _ -> "8sf4wnjhhjnw4fs8qaylc620026clyaq"

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-order-hs"
      mkdir p = createDirectoryIfMissing True (C.unpack p)
      put p contents = do
        mkdir (C.dropWhileEnd (/= '/') p)
        C.writeFile (C.unpack p) contents
      -- Each fixture gets a FRESH store (C++ useFixture): the output names
      -- repeat across fixtures, so a shared store carries one fixture's
      -- reference files into the next and invents edges.
      token store name = store <> "/" <> hashFor name <> "-multi-" <> name
      out store name = DerivationOutput (token store name) "" ""
      drv os = Derivation
        { outputs = Map.fromList os
        , inputDrvs = Map.empty
        , inputSrcs = Set.empty
        , platform = "x86_64-linux"
        , builder = "/bin/sh"
        , args = []
        , environment = Map.empty
        }
      render order = C.intercalate "," (map fst order)
      report :: String -> Derivation -> [RawFilePath] -> RawFilePath -> IO ()
      report label d allPaths chroot = do
        r <- try (contentOutputOrder d allPaths chroot)
        let text = case r of
              Left (e :: SomeException) -> "threw: " <> C.pack (show e)
              Right order -> render order
        hPutStrLn stdout (label ++ " " ++ C.unpack text)
      fixture label = do
        let store = base <> "/" <> label
        mkdir store
        pure store

  -- 1. One output, no references.
  do s <- fixture "f1"
     let d = drv [("out", out s "out")]
         o = token s "out"
     put (o <> "/f") "hello"
     report "single" d [o] ""

  -- 2. out depends on lib: lib must be finalised FIRST.
  do s <- fixture "f2"
     let d = drv [("lib", out s "lib"), ("out", out s "out")]
         lib = token s "lib"; o = token s "out"
     put (lib <> "/f") "lib-content"
     put (o <> "/uses-lib") lib
     report "out-uses-lib" d [o, lib] ""

  -- 3. The reverse: lib depends on out.  Names sort lib<out but the ORDER
  --    must follow the reference, not the name.
  do s <- fixture "f3"
     let d = drv [("lib", out s "lib"), ("out", out s "out")]
         lib = token s "lib"; o = token s "out"
     put (o <> "/f") "out-content"
     put (lib <> "/uses-out") o
     report "lib-uses-out" d [o, lib] ""

  -- 4. A chain a->b->c across three outputs.
  do s <- fixture "f4"
     let d = drv [("aaa", out s "aaa"), ("bbb", out s "bbb"), ("ccc", out s "ccc")]
         a = token s "aaa"; b = token s "bbb"; c = token s "ccc"
     put (c <> "/f") "leaf"
     put (b <> "/uses-c") c
     put (a <> "/uses-b") b
     report "chain" d [a, b, c] ""

  -- 5. A diamond: out uses both lib and dev, dev uses lib.
  do s <- fixture "f5"
     let d = drv [("dev", out s "dev"), ("lib", out s "lib"), ("out", out s "out")]
         dev = token s "dev"; lib = token s "lib"; o = token s "out"
     put (lib <> "/f") "leaf"
     put (dev <> "/uses-lib") lib
     put (o <> "/uses-both") (dev <> " " <> lib)
     report "diamond" d [o, lib, dev] ""

  -- 6. Independent outputs: nothing references anything.
  do s <- fixture "f6"
     let d = drv [("aaa", out s "aaa"), ("zzz", out s "zzz")]
         a = token s "aaa"; z = token s "zzz"
     put (a <> "/f") "a"
     put (z <> "/f") "z"
     report "independent" d [a, z] ""

  -- 7. A cycle: out uses lib and lib uses out.  Must be refused.
  do s <- fixture "f7"
     let d = drv [("lib", out s "lib"), ("out", out s "out")]
         lib = token s "lib"; o = token s "out"
     put (lib <> "/uses-out") o
     put (o <> "/uses-lib") lib
     report "cycle" d [o, lib] ""

  -- 8. A self reference: an output holding its OWN path is not a cycle.
  do s <- fixture "f8"
     let d = drv [("out", out s "out")]
         o = token s "out"
     put (o <> "/self") o
     report "self-ref" d [o] ""

  -- 9. The chroot root is PREFIXED to the physical path.
  do s <- fixture "f9"
     let d = drv [("lib", out s "lib"), ("out", out s "out")]
         lib = token s "lib"; o = token s "out"
         chroot = base <> "/chroot"
     put (chroot <> lib <> "/f") "lib-content"
     put (chroot <> o <> "/uses-lib") lib
     report "chroot" d [o, lib] chroot

  -- 10. A reference to a path that is NOT a sibling output is ignored.
  do s <- fixture "f10"
     let d = drv [("out", out s "out")]
         o = token s "out"
         other = s <> "/" <> hashFor "other" <> "-unrelated"
     put (other <> "/f") "other"
     put (o <> "/uses-other") other
     report "non-sibling-ref" d [o, other] ""

  -- 11. An output whose physical path is MISSING.
  do s <- fixture "f11"
     let d = drv [("lib", out s "lib"), ("out", out s "out")]
         lib = token s "lib"; o = token s "out"
     put (lib <> "/f") "lib-only"
     report "missing-out" d [o, lib] ""

  -- 12. A reference inside a symlink TARGET.
  do s <- fixture "f12"
     let d = drv [("lib", out s "lib"), ("out", out s "out")]
         lib = token s "lib"; o = token s "out"
     put (lib <> "/f") "lib-content"
     mkdir o
     Files.createSymbolicLink lib (o <> "/link")
     report "symlink-ref" d [o, lib] ""