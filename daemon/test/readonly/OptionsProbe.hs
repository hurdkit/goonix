{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
import Goonix.Store.Settings
import Goonix.Store.Wire
import qualified Data.ByteString as B
main = do
  let fields = [encodeInt 0, encodeInt 0, encodeInt 1, encodeInt 1, encodeInt 0, encodeInt 0, encodeInt 0, encodeInt 1, encodeInt 1, encodeInt 1, "build-cores", "4"]
  print (applySetOptions 100 fields (defaultSettings True False))
