{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Derivation
  ( Derivation (..)
  , DerivationOutput (..)
  , parseDerivation
  , writeDerivation
  , isFixedOutput
  , hashDerivationModulo
  , blankOutputPaths
  , derivationOutputPaths
  , derivationOutputPathsWithHash
  , parseHashInfo
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Goonix.Store.Base32 (decodeBase16)
import Goonix.Store.Hash
import Goonix.Store.Path (makeFixedOutputPath, makeOutputPath, storePathToName)

-- Maps and sets deliberately match the C++ writer's byte ordering.
data Derivation = Derivation
  { outputs :: !(Map.Map ByteString DerivationOutput)
  , inputDrvs :: !(Map.Map ByteString (Set.Set ByteString))
  , inputSrcs :: !(Set.Set ByteString)
  , platform :: !ByteString
  , builder :: !ByteString
  , args :: ![ByteString]
  , environment :: !(Map.Map ByteString ByteString)
  } deriving (Eq, Show)

data DerivationOutput = DerivationOutput
  { outputPath :: !ByteString
  , outputHashAlgo :: !ByteString
  , outputHash :: !ByteString
  } deriving (Eq, Show)

data Parser = Parser !ByteString !Int

parseDerivation :: ByteString -> Either String Derivation
parseDerivation input = do
  (drv, Parser rest offset) <- derivation (Parser input 0)
  if offset == B.length rest then pure drv else Left "trailing derivation input"
  where
    derivation start = do
      afterOpen <- expect "Derive([" start
      (outs, afterOutputs) <- list parseOutput afterOpen
      beforeInputs <- expect ",[" afterOutputs
      (ins, afterInputs) <- list parseInput beforeInputs
      beforeSources <- expect ",[" afterInputs
      (srcs, afterSources) <- list parsePath beforeSources
      beforePlatform <- expect "," afterSources
      (platform, afterPlatform) <- string beforePlatform
      beforeBuilder <- expect "," afterPlatform
      (builder, afterBuilder) <- string beforeBuilder
      beforeArgs <- expect ",[" afterBuilder
      (args, afterArgs) <- list string beforeArgs
      beforeEnv <- expect ",[" afterArgs
      (env, afterEnv) <- list parsePair beforeEnv
      final <- expect ")" afterEnv
      pure (Derivation (Map.fromList outs) (Map.fromList ins) (Set.fromList srcs) platform builder args (Map.fromList env), final)

    parseOutput start = do
      afterOpen <- expect "(" start
      (id', afterId) <- string afterOpen
      beforePath <- expect "," afterId
      (path, afterPath) <- parsePath beforePath
      beforeAlgorithm <- expect "," afterPath
      (algorithm, afterAlgorithm) <- string beforeAlgorithm
      beforeHash <- expect "," afterAlgorithm
      (hash, afterHash) <- string beforeHash
      final <- expect ")" afterHash
      pure ((id', DerivationOutput path algorithm hash), final)
    parseInput start = do
      afterOpen <- expect "(" start
      (path, afterPath) <- parsePath afterOpen
      beforeOutputs <- expect ",[" afterPath
      (outs, afterOutputs) <- list string beforeOutputs
      final <- expect ")" afterOutputs
      pure ((path, Set.fromList outs), final)
    parsePair start = do
      afterOpen <- expect "(" start
      (key, afterKey) <- string afterOpen
      beforeValue <- expect "," afterKey
      (value, afterValue) <- string beforeValue
      final <- expect ")" afterValue
      pure ((key, value), final)

list :: (Parser -> Either String (a, Parser)) -> Parser -> Either String ([a], Parser)
list item p@(Parser input offset)
  | offset < B.length input && B.index input offset == 93 = Right ([], advance p)
  | otherwise = do
    next <- if offset < B.length input && B.index input offset == 44
      then Right (advance p) else Right p
    (x, afterItem) <- item next
    (xs, final) <- list item afterItem
    pure (x:xs, final)

parsePath :: Parser -> Either String (ByteString, Parser)
parsePath p = do
  (value, p') <- string p
  if B.null value || B.index value 0 /= 47
    then Left ("bad path `" ++ C.unpack value ++ "' in derivation")
    else Right (value, p')

string :: Parser -> Either String (ByteString, Parser)
string start = do
  opened <- expect "\"" start
  go opened []
  where
    go parser@(Parser input offset) acc
      | offset >= B.length input = Left "unterminated derivation string"
      | otherwise = case B.index input offset of
          34 -> Right (B.pack (reverse acc), Parser input (offset + 1))
          92 -> escaped parser acc
          c -> go (Parser input (offset + 1)) (c:acc)
    escaped (Parser input offset) acc
      | offset + 1 >= B.length input = Left "unterminated derivation escape"
      | otherwise =
          let decoded = case B.index input (offset + 1) of
                110 -> 10
                114 -> 13
                116 -> 9
                c -> c
          in go (Parser input (offset + 2)) (decoded:acc)

expect :: ByteString -> Parser -> Either String Parser
expect wanted (Parser input offset)
  | B.take (B.length wanted) (B.drop offset input) == wanted = Right (Parser input (offset + B.length wanted))
  | otherwise = Left ("expected string `" ++ C.unpack wanted ++ "'")

advance :: Parser -> Parser
advance (Parser input offset) = Parser input (offset + 1)

writeDerivation :: Derivation -> ByteString
writeDerivation drv = "Derive([" <> commas (map writeOutput (Map.toList (outputs drv))) <> "],["
  <> commas (map writeInput (Map.toList (inputDrvs drv))) <> "],"
  <> writeList (Set.toList (inputSrcs drv)) <> "," <> quote (platform drv) <> ","
  <> quote (builder drv) <> "," <> writeList (args drv) <> ",["
  <> commas (map writePair (Map.toList (environment drv))) <> "])"
  where
    commas = B.intercalate ","
    writeList values = "[" <> commas (map quote values) <> "]"
    writeOutput (id', out) = "(" <> quote id' <> "," <> quote (outputPath out) <> "," <> quote (outputHashAlgo out) <> "," <> quote (outputHash out) <> ")"
    writeInput (path, outs) = "(" <> quote path <> "," <> writeList (Set.toList outs) <> ")"
    writePair (key, value) = "(" <> quote key <> "," <> quote value <> ")"

quote :: ByteString -> ByteString
quote input = "\"" <> B.concatMap escape input <> "\""
  where
    escape c = case c of
      34 -> "\\\""; 92 -> "\\\\"; 10 -> "\\n"; 13 -> "\\r"; 9 -> "\\t"; _ -> B.singleton c

isFixedOutput :: Derivation -> Bool
isFixedOutput drv = case Map.toList (outputs drv) of
  [("out", out)] -> not (B.null (outputHash out))
  _ -> False

blankOutputPaths :: Derivation -> Derivation
blankOutputPaths drv = drv
  { outputs = Map.map (\out -> out { outputPath = "" }) (outputs drv)
  , environment = foldl (\env output -> Map.insert output "" env) (environment drv) (Map.keys (outputs drv))
  }

hashDerivationModulo :: Derivation -> (ByteString -> Either String Hash) -> Either String Hash
hashDerivationModulo drv load
  | isFixedOutput drv = case Map.lookup "out" (outputs drv) of
      Just out -> pure (Hash SHA256 (sha256 ("fixed:out:" <> outputHashAlgo out <> ":" <> outputHash out <> ":" <> outputPath out)))
      Nothing -> Left "fixed-output derivation lacks out"
  | otherwise = do
      inputs <- mapM (\(path, outs) -> do
        h <- load path
        pure (encodeHash h, outs)) (Map.toList (inputDrvs drv))
      pure (Hash SHA256 (sha256 (writeDerivation (drv { inputDrvs = Map.fromList inputs }))))
  where
    encodeHash (Hash _ bytes) = encodeHex bytes
    encodeHex = B.concatMap (\b -> B.pack [B.index "0123456789abcdef" (fromIntegral (b `div` 16)), B.index "0123456789abcdef" (fromIntegral (b `mod` 16))])

derivationOutputPaths :: ByteString -> ByteString -> Derivation -> (ByteString -> Either String Hash) -> Either String (Map.Map ByteString ByteString)
derivationOutputPaths store drvPath drv load
  | isFixedOutput drv = case Map.lookup "out" (outputs drv) of
      Nothing -> Left "fixed-output derivation lacks out"
      Just out -> do
        (recursive, algorithm, digest) <- parseHashInfo out
        pure (Map.singleton "out" (makeFixedOutputPath store recursive algorithm digest (derivationName drvPath)))
  | otherwise = do
      h <- hashDerivationModulo (blankOutputPaths drv) load
      derivationOutputPathsWithHash store drvPath h drv
  where
    derivationName path = B.take (B.length name - 4) name
      where name = storePathToName store path

derivationOutputPathsWithHash :: ByteString -> ByteString -> Hash -> Derivation -> Either String (Map.Map ByteString ByteString)
derivationOutputPathsWithHash store drvPath h drv
  | isFixedOutput drv = case Map.lookup "out" (outputs drv) of
      Nothing -> Left "fixed-output derivation lacks out"
      Just out -> do
        (recursive, algorithm, digest) <- parseHashInfo out
        pure (Map.singleton "out" (makeFixedOutputPath store recursive algorithm digest (derivationName drvPath)))
  | otherwise = pure (Map.mapWithKey (\id' _ -> makeOutputPath store id' (hashDigest h) (derivationName drvPath)) (outputs drv))
  where
    derivationName path = B.take (B.length name - 4) name
      where name = storePathToName store path

parseHashInfo :: DerivationOutput -> Either String (Bool, HashAlgorithm, ByteString)
parseHashInfo out = do
  let encoded = outputHashAlgo out
      recursive = "r:" `B.isPrefixOf` encoded
  algorithm <- case algorithmFromName (if recursive then B.drop 2 encoded else encoded) of
    Right value -> Right value
    Left _ -> Left "unknown derivation output hash algorithm"
  digest <- decodeBase16 (outputHash out)
  pure (recursive, algorithm, digest)
