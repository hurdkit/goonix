{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Base64 at the build-record boundary, never in archive signatures.
-- libgcrypt's advanced S-expression can contain raw high bytes.  Those bytes
-- are ISO-8859-1 data, not UTF-8 text: encode them before putting a record in
-- the database or on the graph wire.  A pre-base64 stored S-expression is
-- encoded at load, byte for byte; any other malformed field is refused.
module Goonix.Store.RecordSignature
  ( InvalidRecordSignature (..)
  , encodeRecordSignature
  , decodeRecordSignature
  , loadRecordSignature
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (when)
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word (Word32, Word8)

newtype InvalidRecordSignature = InvalidRecordSignature String deriving (Eq, Show)
instance Exception InvalidRecordSignature

encodeRecordSignature :: ByteString -> ByteString
encodeRecordSignature raw = B.pack (go raw)
  where
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    digit n = B.index alphabet (fromIntegral (n :: Int))
    go bytes
      | B.null bytes = []
      | otherwise = let
          (chunk, rest) = B.splitAt 3 bytes
          [a, b, c] = map fromIntegral (B.unpack chunk ++ replicate (3 - B.length chunk) 0) :: [Int]
          number = (a `shiftL` 16) .|. (b `shiftL` 8) .|. c
          body = [digit (number `shiftR` 18), digit ((number `shiftR` 12) .&. 63),
                  digit ((number `shiftR` 6) .&. 63), digit (number .&. 63)]
          encoded = take (B.length chunk + 1) body ++ replicate (3 - B.length chunk) 61
        in encoded ++ go rest

invalid :: String -> IO a
invalid reason = throwIO (InvalidRecordSignature
  ("goonix: record signature is not valid base64 (" ++ reason ++ ")"))

decodeRecordSignature :: ByteString -> IO ByteString
decodeRecordSignature encoded
  | B.null encoded = invalid "length"
  | B.length encoded `mod` 4 /= 0 = invalid "length"
  | otherwise = B.concat <$> traverse group [0, 4 .. B.length encoded - 4]
  where
    group offset = do
      let lastGroup = offset + 4 == B.length encoded
          byte n = B.index encoded (offset + n)
          padding = length [() | n <- [2, 3], byte n == 61]
      (a, b) <- case (byte 0, byte 1) of
        (x, y) -> case (value x, value y) of
          (Just first, Just second) -> pure (first, second :: Word32)
          _ -> invalid "alphabet"
      (third, fourth) <- case (byte 2, byte 3) of
        (61, 61) | lastGroup -> pure (0, 0)
        (61, _) -> invalid "padding"
        (_, 61) | lastGroup -> maybe (invalid "alphabet") (pure . (, 0)) (value (byte 2))
        (_, 61) -> invalid "padding"
        (x, y) -> case (value x, value y) of
          (Just third', Just fourth') -> pure (third' :: Word32, fourth' :: Word32)
          _ -> invalid "alphabet"
      when (padding > 2 || (not lastGroup && padding /= 0)) (invalid "padding")
      let number = (a `shiftL` 18) .|. (b `shiftL` 12) .|. (third `shiftL` 6) .|. fourth
      pure (B.pack ([fromIntegral (number `shiftR` 16)]
        ++ [fromIntegral (number `shiftR` 8) | padding < 2]
        ++ [fromIntegral number | padding < 1]))
    value :: Word8 -> Maybe Word32
    value x = case fromIntegral x :: Word32 of
      n | n >= 65 && n <= 90 -> Just (n - 65)
        | n >= 97 && n <= 122 -> Just (n - 97 + 26)
        | n >= 48 && n <= 57 -> Just (n - 48 + 52)
        | n == 43 -> Just 62
        | n == 47 -> Just 63
        | otherwise -> Nothing

-- | The only legacy exception: a raw stored S-expression is normalized at
-- load.  Graph input never uses this rule; it must already carry base64.
loadRecordSignature :: ByteString -> IO ByteString
loadRecordSignature signature
  | "(" `B.isPrefixOf` signature = pure (encodeRecordSignature signature)
  | otherwise = decodeRecordSignature signature >> pure signature
