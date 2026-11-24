{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Regression: rewriteRegularFile's streaming result must equal the WHOLE-FILE
-- result, whatever offset a match sits at and however read() split the file.
--
-- Two defects in the prefix-hold-back loop (shared with C++ ca.cc):
-- (a) a COMPLETE plain self-reference ending exactly at the emit point, whose
--     token's last character equals its first, loses its last byte to the
--     hold-back; the chunk then holds the token minus one byte and the 8-byte
--     fragment check REJECTS a valid file.
-- (b) an opaque occurrence (UTF-32LE / UTF-16LE encoding of FROM, or an 8-byte
--     fragment) that STARTS before the emit point and ends after it is split
--     across two chunks, so neither sees all of it and the file is ACCEPTED
--     with a hidden reference.
--
-- The oracle is replaceWhole over the whole file - a different code path from
-- the streaming loop.  Sweeps cover the offsets around each boundary: the
-- window for (a) is one byte wide, so a hand-picked offset proves nothing.
--
-- Fails before the fix, passes after.  Run: daemon/test/rewrite-boundary.sh
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import qualified System.Posix.Files.ByteString as Files

import Goonix.Store.CaBuild (replaceWhole, rewriteTree)

-- A 32-character token whose LAST character equals its FIRST: the shape that
-- makes a complete match look like a partial one to a prefix test.
from :: B.ByteString
from = C.pack ("t" ++ take 30 (cycle "eout") ++ "t")

to :: B.ByteString
to = C.pack (take 32 (cycle "0123456789abcdfghijklmnpqrsvwxyz"))

readSize, keep :: Int
readSize = 128 * 1024
keep = B.length from * 4 - 1

-- | The whole-file result: Left = rejected (with the message), Right = bytes.
oracle :: B.ByteString -> Either String B.ByteString
oracle bytes = replaceWhole bytes from to "<file>" True

utfEncode :: Int -> B.ByteString -> B.ByteString
utfEncode width = B.concatMap (\c -> c `B.cons` B.replicate (width - 1) 0)

-- | Run the streaming rewrite on a real file and report Left/Right like the
-- oracle, so the two are directly comparable.
streaming :: C.ByteString -> B.ByteString -> IO (Either String B.ByteString)
streaming path bytes = do
  B.writeFile (C.unpack path) bytes
  -- rewriteTree on a single regular file goes through rewriteRegularFile, the
  -- streaming loop under test, without needing a new export.
  r <- try (rewriteTree path from to)
  case r of
    Left (e :: SomeException) -> pure (Left (show e))
    Right () -> Right <$> B.readFile (C.unpack path)

-- Compare only the VERDICT and, when accepted, the bytes.  The rejection
-- message names a byte offset, which legitimately differs between a whole-file
-- scan and a chunked one; the requirement is that both reject.
sameVerdict :: Either String B.ByteString -> Either String B.ByteString -> Bool
sameVerdict (Left _) (Left _) = True
sameVerdict (Right a) (Right b) = a == b
sameVerdict _ _ = False

describe :: Either String B.ByteString -> String
describe (Left e) = "REJECTED: " ++ e
describe (Right b) = "ACCEPTED " ++ show (B.length b) ++ " bytes"

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/goonix-rewrite-boundary"
      mkdir p = createDirectoryIfMissing True (C.unpack p)
  mkdir base
  -- (a) A plain token ending exactly `keep` bytes before EOF, and exactly
  --     `keep` bytes before the first read's end.  Swept either side.
  let plainCases =
        [ ("plain-eof-" ++ show d, pad <> from <> C.pack (replicate (keep + d) 'z'))
        | d <- [-2 .. 2]
        , let pad = C.pack (replicate 40 'x')
        , keep + d >= 0 ]
        ++
        [ ("plain-read-" ++ show d,
            C.pack (replicate (readSize - keep - B.length from + d) 'x')
              <> from <> C.pack (replicate 200 'z'))
        | d <- [-2 .. 2]
        , readSize - keep - B.length from + d >= 0 ]
      -- (b) Opaque occurrences straddling the first read's emit point.
      opaquePatterns =
        [ ("utf32", utfEncode 4 from)
        , ("utf16", utfEncode 2 from)
        , ("frag0", B.take 8 from)
        , ("frag12", B.take 8 (B.drop 12 from))
        ]
      emit = readSize - keep
      opaqueCases =
        [ (name ++ "-straddle-" ++ show d,
            C.pack (replicate (emit + d - B.length pat `div` 2) 'x')
              <> pat <> C.pack (replicate 200 'z'))
        | (name, pat) <- opaquePatterns
        , d <- [-2 .. 2]
        , emit + d - B.length pat `div` 2 >= 0 ]
      -- The same opaque shapes wholly inside one chunk must still be rejected,
      -- and wholly inside the lookahead must be rejected in a later round.
      controlCases =
        [ ("utf32-early", C.pack (replicate 10 'x') <> utfEncode 4 from <> C.pack (replicate 200 'z'))
        , ("utf16-early", C.pack (replicate 10 'x') <> utfEncode 2 from <> C.pack (replicate 200 'z'))
        , ("frag-early", C.pack (replicate 10 'x') <> B.take 8 from <> C.pack (replicate 200 'z'))
        , ("plain-only", C.pack (replicate 10 'x') <> from <> C.pack (replicate 10 'z'))
        , ("no-reference", C.pack (replicate 500 'x'))
        ]
      cases = plainCases ++ opaqueCases ++ controlCases
  results <- forM (zip [0 :: Int ..] cases) $ \(i, (label, bytes)) -> do
    let path = base <> "/" <> C.pack ("case" ++ show i)
    expected <- pure (oracle bytes)
    actual <- streaming path bytes
    if sameVerdict expected actual
      then do
        putStrLn ("PASS " ++ label)
        pure True
      else do
        putStrLn ("FAIL " ++ label)
        hPutStrLn stderr ("  " ++ label)
        hPutStrLn stderr ("    whole-file: " ++ describe expected)
        hPutStrLn stderr ("    streaming:  " ++ describe actual)
        pure False
  let failed = length (filter not results)
  if failed == 0
    then putStrLn ("REWRITE_BOUNDARY: PASS " ++ show (length cases) ++ " cases")
    else do
      putStrLn ("REWRITE_BOUNDARY: FAIL " ++ show failed ++ " of " ++ show (length cases))
      exitFailure