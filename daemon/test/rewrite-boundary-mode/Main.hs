{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Haskell side of the FORWARD-rewrite boundary parity probe.  Same fixtures
-- as nix/libstore/rewrite-boundary-probe.cc; daemon/test/rewrite-boundary-mode.sh
-- diffs them.
--
-- Each case reports the streaming verdict and whether it agrees with the
-- whole-file oracle (replaceWhole), so a side that is internally inconsistent is
-- visible even if both sides happen to agree with each other.
module Main (main) where

import Control.Exception (SomeException, try)
import Data.List (isPrefixOf)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stdout)

import Goonix.Store.Base32 (encodeBase16)
import Goonix.Store.CaBuild (replaceWhole, rewriteTree)
import Goonix.Store.Hash (sha256)

-- A 32-character token whose LAST character equals its FIRST.
from, to :: B.ByteString
from = C.pack ("t" ++ take 30 (cycle "eout") ++ "t")
to = C.pack (take 32 (cycle "0123456789abcdfghijklmnpqrsvwxyz"))

readSize, keep :: Int
readSize = 128 * 1024
keep = B.length from * 4 - 1

pad :: Int -> Char -> B.ByteString
pad n c = C.pack (replicate n c)

utfEncode :: Int -> B.ByteString -> B.ByteString
utfEncode width = B.concatMap (\c -> c `B.cons` B.replicate (width - 1) 0)

digest :: B.ByteString -> String
digest = C.unpack . encodeBase16 . sha256

oracle :: B.ByteString -> String
oracle body = case replaceWhole body from to "<memory>" True of
  Left e -> "rejected: " ++ e
  Right rewritten -> "accepted " ++ digest rewritten

-- | The exception's MESSAGE, without the "user error (...)" wrapper that `show`
-- adds, so it compares verbatim with the C++ e.what().
exceptionMessage :: SomeException -> String
exceptionMessage e =
  let shown = show e
      wrapper = "user error (" :: String
  in if wrapper `isPrefixOf` shown && not (null shown)
       then init (drop (length wrapper) shown)
       else shown

streaming :: C.ByteString -> B.ByteString -> IO String
streaming path body = do
  B.writeFile (C.unpack path) body
  r <- try (rewriteTree path from to)
  case r of
    Left (e :: SomeException) -> pure ("rejected: " ++ exceptionMessage e)
    Right () -> do
      got <- try (B.readFile (C.unpack path))
      pure $ case got of
        Left (_ :: SomeException) -> "unreadable"
        Right bytes -> "accepted " ++ digest bytes

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/ca-rewrite-boundary-hs"
  createDirectoryIfMissing True (C.unpack base)
  let plainEof =
        [ ("plain-eof-" ++ show d, pad 40 'x' <> from <> pad (keep + d) 'z')
        | d <- [-2 .. 2], keep + d >= 0 ]
      plainRead =
        [ ("plain-read-" ++ show d,
            pad (readSize - keep - B.length from + d) 'x' <> from <> pad 200 'z')
        | d <- [-2 .. 2], readSize - keep - B.length from + d >= 0 ]
      pats = [ ("utf32", utfEncode 4 from)
             , ("utf16", utfEncode 2 from)
             , ("frag0", B.take 8 from)
             , ("frag12", B.take 8 (B.drop 12 from)) ]
      emit = readSize - keep
      straddle =
        [ (name ++ "-straddle-" ++ show d,
            pad (emit + d - B.length pat `div` 2) 'x' <> pat <> pad 200 'z')
        | (name, pat) <- pats, d <- [-2 .. 2]
        , emit + d - B.length pat `div` 2 >= 0 ]
      controls =
        [ ("utf32-early", pad 10 'x' <> utfEncode 4 from <> pad 200 'z')
        , ("utf16-early", pad 10 'x' <> utfEncode 2 from <> pad 200 'z')
        , ("frag-early", pad 10 'x' <> B.take 8 from <> pad 200 'z')
        , ("plain-only", pad 10 'x' <> from <> pad 10 'z')
        , ("no-reference", pad 500 'x')
        ]
      -- Rejections whose FILE offset is only correct if the consumed byte count
      -- is carried across rounds: past two whole reads, and in the final tail.
      offsets =
        [ ("frag-third-read", pad (2 * readSize + 5000) 'x' <> B.take 8 from <> pad 200 'z')
        , ("utf32-third-read", pad (2 * readSize + 5000) 'x' <> utfEncode 4 from <> pad 200 'z')
        , ("frag-final-tail", pad readSize 'x' <> B.take 8 from)
        , ("utf16-final-tail", pad readSize 'x' <> utfEncode 2 from)
        ]
      cases = plainEof ++ plainRead ++ straddle ++ controls ++ offsets
      -- The oracle names <memory>, the streaming run names the real path.
      -- Normalise both to <file> so the comparison is on the MESSAGE and the
      -- byte OFFSET.  The exception wrapper is stripped in exceptionMessage.
      norm :: C.ByteString -> String -> String
      norm path = replaceStr (C.unpack path) "<file>"
                    . replaceStr "<memory>" "<file>"
      replaceStr :: String -> String -> String -> String
      replaceStr needle repl = go
        where go s
                | null s = ""
                | needle `isPrefixOf` s = repl ++ go (drop (length needle) s)
                | otherwise = head s : go (tail s)
  mapM_ (\(i, (label, body)) -> do
      let path = base <> "/" <> C.pack ("case" ++ show (i :: Int))
          want = norm path (oracle body)
      gotRaw <- streaming path body
      let got = norm path gotRaw
      hPutStrLn stdout (label ++ " " ++ got ++ " self-consistent="
        ++ (if want == got then "1" else "0")))
    (zip [0 ..] cases)
