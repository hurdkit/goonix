{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Probe the Haskell inverseTree with the SAME fixtures as the C++ probe
-- (nix/libstore/inverse-probe.cc).  Compares the verification DIGEST itself.
-- daemon/test/inverse-mode.sh diffs them.
module Main (main) where

import Control.Exception (SomeException, try)
import qualified Foreign.C.String
import qualified Foreign.C.Types
import System.Posix.Types (CMode (..))
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stdout)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Files.ByteString as Files

import Goonix.Store.CaBuild (inverseTree)

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-inverse-hs"
      fin = C.pack (replicate 32 'f')
      tok = C.pack (replicate 32 't')
      none = Map.empty
      mkdir p = createDirectoryIfMissing True (C.unpack p)
      report :: String -> RawFilePath -> Map.Map C.ByteString C.ByteString -> IO ()
      report label p sib = do
        r <- try (inverseTree p fin tok sib)
        let out = case r of
              Right h -> C.unpack h
              Left (_ :: SomeException) -> "threw"
        hPutStrLn stdout (label ++ " " ++ out)

  let plain = base <> "/plain"
  mkdir plain; C.writeFile (C.unpack (plain <> "/f")) "hello"
  report "plain-file" (plain <> "/f") none

  let ex = base <> "/exec"
  mkdir ex; C.writeFile (C.unpack (ex <> "/f")) "hello"
  Files.setFileMode (ex <> "/f") 0o555
  report "exec-file" (ex <> "/f") none

  let st = base <> "/start"
  mkdir st; C.writeFile (C.unpack (st <> "/f")) (fin <> "tail")
  report "final-at-start" (st <> "/f") none

  let en = base <> "/end"
  mkdir en; C.writeFile (C.unpack (en <> "/f")) ("head" <> fin)
  report "final-at-end" (en <> "/f") none

  mapM_ (\split -> do
    let d = base <> "/split" <> C.pack (show (split :: Int))
    mkdir d
    C.writeFile (C.unpack (d <> "/f"))
      (C.pack (replicate (128 * 1024 - split) 'x') <> fin)
    report ("final-split-" ++ show split) (d <> "/f") none) [1, 16, 31, 32]

  let lk = base <> "/link"
  mkdir lk
  Files.createSymbolicLink ("/gnu/store/" <> fin <> "-x") (lk <> "/l")
  report "symlink-target" (lk <> "/l") none

  let dr = base <> "/dir"
  mkdir dr
  C.writeFile (C.unpack (dr <> "/" <> fin <> "-a")) "one"
  C.writeFile (C.unpack (dr <> "/" <> tok <> "-z")) "two"
  C.writeFile (C.unpack (dr <> "/mmm")) "three"
  report "dir-inverse-sort" dr none

  let sb = base <> "/sib"
      s1t = C.pack (replicate 32 'a'); s1f = C.pack (replicate 32 'b')
      s2t = C.pack (replicate 32 'c'); s2f = C.pack (replicate 32 'd')
  mkdir sb
  C.writeFile (C.unpack (sb <> "/f")) (s1f <> "|" <> s2f <> "|" <> fin)
  report "siblings" (sb <> "/f") (Map.fromList
    [ ("/gnu/store/" <> s1t <> "-one", "/gnu/store/" <> s1f <> "-one")
    , ("/gnu/store/" <> s2t <> "-two", "/gnu/store/" <> s2f <> "-two") ])

  let ff = base <> "/fifo"
  mkdir ff
  mkfifo (ff <> "/p")
  report "fifo-refused" (ff <> "/p") none

foreign import ccall unsafe "mkfifo" c_mkfifo :: Foreign.C.String.CString -> CMode -> IO Foreign.C.Types.CInt

mkfifo :: RawFilePath -> IO ()
mkfifo p = do
  r <- C.useAsCString p $ \cp -> c_mkfifo cp 0o600
  if r /= 0 then error "mkfifo failed" else pure ()