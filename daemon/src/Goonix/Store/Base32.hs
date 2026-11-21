{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Base32
  ( encodeBase16
  , decodeBase16
  , encodeBase32
  , decodeBase32
  , base32Alphabet
  , base32Length
  ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Char (ord)
import Data.Word (Word8)

base16Alphabet, base32Alphabet :: ByteString
base16Alphabet = "0123456789abcdef"
base32Alphabet = "0123456789abcdfghijklmnpqrsvwxyz"

encodeBase16 :: ByteString -> ByteString
encodeBase16 input = B.concatMap encodeByte input
  where
    encodeByte byte = B.pack
      [ B.index base16Alphabet (fromIntegral (byte `shiftR` 4))
      , B.index base16Alphabet (fromIntegral (byte .&. 15))
      ]

decodeBase16 :: ByteString -> Either String ByteString
decodeBase16 input
  | odd (B.length input) = Left "odd-length base16"
  | otherwise = B.pack <$> pairs (C.unpack input)
  where
    pairs [] = Right []
    pairs (a:b:rest) = case (hex a, hex b) of
      (Just x, Just y) -> ((x * 16 + y) :) <$> pairs rest
      _ -> Left "invalid base16 character"
    pairs _ = Left "odd-length base16"
    hex c
      | c >= '0' && c <= '9' = Just (fromIntegral (ord c - ord '0'))
      | c >= 'a' && c <= 'f' = Just (fromIntegral (ord c - ord 'a' + 10))
      | c >= 'A' && c <= 'F' = Just (fromIntegral (ord c - ord 'A' + 10))
      | otherwise = Nothing

base32Length :: Int -> Int
base32Length size = (size * 8 - 1) `div` 5 + 1

encodeBase32 :: ByteString -> ByteString
encodeBase32 input = B.pack
  [ B.index base32Alphabet (fromIntegral (digit input n))
  | n <- reverse [0 .. base32Length (B.length input) - 1]
  ]
  where
    digit bytes n =
      let bit = n * 5
          i = bit `div` 8
          j = bit `mod` 8
          low = B.index bytes i `shiftR` j
          high = if i >= B.length bytes - 1 then 0 else B.index bytes (i + 1) `shiftL` (8 - j)
      in (low .|. high) .&. 31

decodeBase32 :: ByteString -> Either String ByteString
decodeBase32 input = do
  digits <- mapM decodeDigit (reverse (B.unpack input))
  let size = (length digits * 5) `div` 8
  pure (B.pack [byteAt digits i | i <- [0 .. size - 1]])
  where
    byteAt :: [Word8] -> Int -> Word8
    byteAt digits i =
      let lowBit = i * 8
          highBit = lowBit + 7
          relevant =
            [ (n, n * 5 - lowBit)
            | n <- [0 .. length digits - 1]
            , n * 5 <= highBit
            , n * 5 + 4 >= lowBit
            ]
          contributions = [shiftContribution (digits !! n) offset | (n, offset) <- relevant] :: [Int]
      in fromIntegral (foldl (.|.) 0 contributions) .&. 255
    shiftContribution :: Word8 -> Int -> Int
    shiftContribution digit offset
      | offset >= 0 = fromIntegral digit `shiftL` offset
      | otherwise = fromIntegral digit `shiftR` negate offset
    decodeDigit byte = case B.elemIndex byte base32Alphabet of
      Nothing -> Left "invalid base32 character"
      Just n -> Right (fromIntegral n)
