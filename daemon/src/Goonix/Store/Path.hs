{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Path
  ( validateStoreName
  , makeStorePath
  , makeOutputPath
  , makeFixedOutputPath
  , makeTextPath
  , storePathToName
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.List (sort)
import Goonix.Store.Base32
import Goonix.Store.Hash

validateStoreName :: ByteString -> Either String ()
validateStoreName name
  | B.null name = Left "empty string is not a valid name"
  | B.index name 0 == 46 = Left ("invalid name: `" ++ C.unpack name ++ "' (can't begin with dot)")
  | Just c <- B.find (\c -> not ((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c `B.elem` "+-._?=")) name =
      Left ("invalid character `" ++ [C.index (B.singleton c) 0] ++ "' in name `" ++ C.unpack name ++ "'")
  | otherwise = Right ()

makeStorePath :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString
makeStorePath store type' hash name =
  let input = type' <> ":sha256:" <> encodeBase16 hash <> ":" <> store <> ":" <> name
      compressed = compressHash 20 (sha256 input)
  in store <> "/" <> encodeBase32 compressed <> "-" <> name

makeOutputPath :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString
makeOutputPath store id' hash name = makeStorePath store ("output:" <> id') hash (name <> if id' == "out" then "" else "-" <> id')

makeFixedOutputPath :: ByteString -> Bool -> HashAlgorithm -> ByteString -> ByteString -> ByteString
makeFixedOutputPath store recursive algorithm hash name
  | algorithm == SHA256 && recursive = makeStorePath store "source" hash name
  | otherwise = makeStorePath store "output:out"
      (sha256 ("fixed:out:" <> (if recursive then "r:" else "") <> algorithmName algorithm <> ":" <> encodeBase16 hash <> ":")) name

makeTextPath :: ByteString -> ByteString -> ByteString -> [ByteString] -> ByteString
makeTextPath store name contents references =
  makeStorePath store (B.intercalate ":" ("text" : sort references)) (sha256 contents) name

storePathToName :: ByteString -> ByteString -> ByteString
storePathToName store path = B.drop (B.length store + 34) path
