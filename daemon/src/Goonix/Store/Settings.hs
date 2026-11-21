{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Settings
  ( Settings (..)
  , defaultSettings
  , setSetting
  , setting
  , settingBool
  , settingInt
  , applySetOptions
  , substituteURLs
  , parseDaemonOptions
  , DaemonOptions (..)
  , defaultDaemonOptions
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import Data.Word (Word32)
import qualified Goonix.Config as Config

data Settings = Settings
  { values :: !(Map.Map ByteString ByteString)
  , trusted :: !Bool
  , remote :: !Bool
  , keepFailed :: !Bool
  , keepGoing :: !Bool
  , verbosity :: !Int
  , buildVerbosity :: !Int
  , logType :: !Int
  , printBuildTrace :: !Bool
  } deriving (Eq, Show)

defaultSettings :: Bool -> Bool -> Settings
defaultSettings isTrusted isRemote = Settings Map.empty isTrusted isRemote False False 1 0 0 False

setSetting :: ByteString -> ByteString -> Settings -> Settings
setSetting key value settings = settings { values = Map.insert key value (values settings) }

setting :: ByteString -> ByteString -> Settings -> ByteString
setting key fallback settings = Map.findWithDefault fallback key (values settings)

settingBool :: ByteString -> Bool -> Settings -> Bool
settingBool key fallback settings = case setting key (if fallback then "true" else "false") settings of
  "true" -> True
  "false" -> False
  _ -> fallback

settingInt :: ByteString -> Int -> Settings -> Int
settingInt key fallback settings = case reads (C.unpack (setting key (C.pack (show fallback)) settings)) of
  [(number, "")] -> number
  _ -> fallback

applySetOptions :: Word32 -> [ByteString] -> Settings -> Either String Settings
applySetOptions minor fields initial = do
  (keepFailedValue, rest1) <- takeField fields
  (keepGoingValue, rest2) <- takeField rest1
  (fallbackValue, rest3) <- takeField rest2
  (verbosityValue, rest4) <- takeField rest3
  (afterOldJobs, rest5) <- if minor < 0x61 then takeFields 2 rest4 else Right ([], rest4)
  (buildHook, rest6) <- if minor >= 2 then takeField rest5 else Right ("0", rest5)
  (buildVerbosityValue, rest7) <- if minor >= 4 then takeField rest6 else Right ("0", rest6)
  (logTypeValue, rest8) <- if minor >= 4 then takeField rest7 else Right ("0", rest7)
  (traceValue, rest9) <- if minor >= 4 then takeField rest8 else Right ("0", rest8)
  (cores, rest10) <- if minor >= 6 && minor < 0x61 then takeField rest9 else Right ("0", rest9)
  (useSubstitutes, rest11) <- if minor >= 10 then takeField rest10 else Right ("0", rest10)
  pairs <- if minor >= 12 then readPairs rest11 else Right []
  let settings0 = initial
        { keepFailed = not (remote initial) && keepFailedValue /= zero
        , keepGoing = keepGoingValue /= zero
        , verbosity = intValue verbosityValue
        , buildVerbosity = intValue buildVerbosityValue
        , logType = intValue logTypeValue
        , printBuildTrace = traceValue /= zero
        }
      settings1 = setSetting "build-fallback" (if fallbackValue == zero then "false" else "true") settings0
      settings2 = if minor < 0x61 then applyNumberPairs ["build-max-jobs", "build-max-silent-time"] afterOldJobs settings1 else settings1
      settings3 = if minor >= 6 && minor < 0x61 then setSetting "build-cores" cores settings2 else settings2
      settings4 = if minor >= 10 && settingBool "build-use-substitutes" True settings3
        then setSetting "build-use-substitutes" (if useSubstitutes == zero then "false" else "true") settings3 else settings3
      settings5 = if minor >= 2
        then setSetting "build-use-build-hook" (if buildHook == zero then "false" else "true") settings4
        else settings4
  pure (foldl applyPair settings5 pairs)
  where
    zero = B.replicate 8 0
    intValue = littleInt
    applyPair settings (key, value)
      | key `elem` ["build-timeout", "build-max-silent-time", "build-max-log-size", "build-max-jobs", "build-cores", "build-repeat", "multiplexed-build-output"] = setSetting key value settings
      | key == "user-name" = settings
      | trusted settings = setSetting key value settings
      | otherwise = setSetting ("untrusted-" <> key) value settings

applyNumberPairs :: [ByteString] -> [ByteString] -> Settings -> Settings
applyNumberPairs keys numbers settings = foldl (\s (key, value) -> setSetting key value s) settings (zip keys numbers)

substituteURLs :: Settings -> [ByteString]
substituteURLs settings
  | not (settingBool "build-use-substitutes" False settings) = []
  | otherwise = C.words (setting "untrusted-substitute-urls" (setting "substitute-urls" "" settings) settings)

takeField :: [ByteString] -> Either String (ByteString, [ByteString])
takeField [] = Left "truncated set-options"
takeField (x:xs) = Right (x, xs)

takeFields :: Int -> [ByteString] -> Either String ([ByteString], [ByteString])
takeFields count fields
  | length fields < count = Left "truncated set-options"
  | otherwise = Right (splitAt count fields)

readPairs :: [ByteString] -> Either String [(ByteString, ByteString)]
readPairs [] = Left "missing option-pair count"
readPairs (countBytes:rest) = go (littleInt countBytes) rest
  where
    go 0 fields | null fields = Right []
                | otherwise = Left "trailing set-options fields"
    go n fields = do
      (key, rest1) <- takeField fields
      (value, rest2) <- takeField rest1
      ((key, value) :) <$> go (n - 1) rest2

littleInt :: ByteString -> Int
littleInt bytes = sum [fromIntegral (B.index bytes i) * (256 ^ i) | i <- [0 .. min 7 (B.length bytes - 1)]]

data DaemonOptions = DaemonOptions
  { listenOptions :: ![ByteString]
  , settings :: !Settings
  , debug :: !Bool
  } deriving (Eq, Show)

defaultDaemonOptions :: DaemonOptions
defaultDaemonOptions = DaemonOptions []
  (setSetting "substitute-urls" (C.pack Config.defaultSubstituteUrls)
    (setSetting "build-use-substitutes" "true" (defaultSettings True False))) False

parseDaemonOptions :: [ByteString] -> Either String DaemonOptions
parseDaemonOptions = go defaultDaemonOptions
  where
    go options [] = Right options
    go options ("--debug":rest) = go options { debug = True } rest
    go options ("--listen":socket:rest) = go options { listenOptions = listenOptions options ++ [socket] } rest
    go options (arg:rest)
      | Just socket <- stripPrefix "--listen=" arg = go options { listenOptions = listenOptions options ++ [socket] } rest
      | Just _ <- stripPrefix "--store=" arg = go options rest
      | Just value <- stripPrefix "--substitute-urls=" arg = go (put "substitute-urls" value options) rest
      | arg == "--substitute-urls" = withValue arg rest $ \value more -> go (put "substitute-urls" value options) more
      | Just value <- stripPrefix "--max-jobs=" arg = go (put "build-max-jobs" value options) rest
      | Just value <- stripPrefix "--cores=" arg = go (put "build-cores" value options) rest
      | Just value <- stripPrefix "--timeout=" arg = go (put "build-timeout" value options) rest
      | Just value <- stripPrefix "--max-silent-time=" arg = go (put "build-max-silent-time" value options) rest
      | Just value <- stripPrefix "--rounds=" arg = go (put "build-repeat" value options) rest
      | Just value <- stripPrefix "--build-users-group=" arg = go (put "build-users-group" value options) rest
      | arg == "--no-substitutes" = go (put "build-use-substitutes" "false" options) rest
      | arg == "--cache-failures" = go (put "build-cache-failures" "true" options) rest
      | arg == "--no-offload" || arg == "--no-build-hook" = go (put "build-use-build-hook" "false" options) rest
      | arg == "--disable-chroot" = go (put "build-use-sandbox" "false" options) rest
      | arg == "--disable-deduplication" || arg == "--disable-store-optimization" = go (put "build-deduplicate" "false" options) rest
      | arg == "--allow-aslr" = go (put "build-allow-aslr" "true" options) rest
      | arg == "--lose-logs" = go (put "build-keep-logs" "false" options) rest
      | arg == "--disable-log-compression" || arg == "--no-compress-build-logs" = go (put "build-log-compression" "none" options) rest
      | Just value <- stripPrefix "--log-compression=" arg = go (put "build-log-compression" value options) rest
      | Just value <- stripPrefix "--build-log-compression=" arg = go (put "build-log-compression" value options) rest
      | arg == "--gc-keep-outputs" = optionalBool "gc-keep-outputs" options rest
      | arg == "--gc-keep-derivations" = optionalBool "gc-keep-derivations" options rest
      | arg == "--impersonate-linux-2.6" = go (put "build-impersonate-linux-26" "true" options) rest
      | arg == "--no-impersonate-linux-2.6" = go (put "build-impersonate-linux-26" "false" options) rest
      | arg == "--isolate-host-loopback" = go (put "build-isolate-host-loopback" "true" options) rest
      | arg == "--no-gc-warning" = go options rest
      | arg == "--system" = withValue arg rest $ \value more -> go (put "system" value options) more
      | arg == "--chroot-directory" = withValue arg rest $ \value more -> go (put "build-chroot-dirs" value options) more
      | Just value <- stripPrefix "--chroot-directory=" arg = go (put "build-chroot-dirs" value options) rest
      | arg == "--discover" = optionalBool "build-discover" options rest
      | arg == "--no-discover" = go (put "build-discover" "false" options) rest
      | otherwise = Left ("unrecognized daemon option: " ++ C.unpack arg)
    put key value options = options { settings = setSetting key value (settings options) }
    withValue arg values action = case values of
      value:more -> action value more
      [] -> Left (C.unpack arg ++ " requires a value")
    optionalBool key options rest = case rest of
      value:more | isYesNo value -> go (put key (if isYes value then "true" else "false") options) more
      _ -> go (put key "true" options) rest

isYesNo :: ByteString -> Bool
isYesNo value = value `elem` ["yes", "no", "true", "false"]

isYes :: ByteString -> Bool
isYes value = value `elem` ["yes", "true"]

stripPrefix :: ByteString -> ByteString -> Maybe ByteString
stripPrefix prefix value
  | B.isPrefixOf prefix value = Just (B.drop (B.length prefix) value)
  | otherwise = Nothing
