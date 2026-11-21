{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.References
  ( scanReferences
  , scanReferencesBytes
  , scanChunks
  , naiveReferences
  , referenceHash
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Goonix.Store.Base32 (base32Alphabet)
import Goonix.Store.Hash (Hash)
import Goonix.Store.Nar (hashNarWith)
import System.Posix.ByteString (RawFilePath)

-- Only the 32-byte hash part is looked for, as in references.cc.  A path
-- whose hash is already present is not searched for again.  Keeping every
-- path for a hash is necessary: two store names can have the same hash.
scanReferences :: RawFilePath -> [RawFilePath] -> IO (Set.Set RawFilePath, Hash)
scanReferences path candidates =
  scanReferencesBytes path (candidateTable candidates)

scanReferencesBytes :: RawFilePath -> Map.Map ByteString [RawFilePath] -> IO (Set.Set RawFilePath, Hash)
scanReferencesBytes path table = hashNarWith path $ \chunk state ->
  scanChunks [chunk] table state

-- The 31-byte carry preserves candidates crossing a chunk boundary.  The
-- same function is used by the streaming NAR scanner and the property tests.
scanChunks :: [ByteString] -> Map.Map ByteString [RawFilePath]
  -> (ByteString, Set.Set RawFilePath) -> (ByteString, Set.Set RawFilePath)
scanChunks chunks table (initialTail, initialFound) =
  foldl step (initialTail, initialFound) chunks
  where
    step (carry, found) chunk =
      let combined = carry <> chunk
          found' = search combined table found
          carry' = B.drop (max 0 (B.length combined - 31)) combined
      in (carry', found')

candidateTable :: [RawFilePath] -> Map.Map ByteString [RawFilePath]
candidateTable = Map.fromListWith (++) . concatMap candidate
  where
    candidate path = case referenceHash path of
      "" -> []
      hash -> [(hash, [path])]

referenceHash :: RawFilePath -> ByteString
referenceHash path =
  let name = snd (C.breakEnd (== '/') path)
      hash = B.takeWhile (/= 45) name
  in if B.length hash /= 32 || not (B.all (`B.elem` base32Alphabet) hash)
    then B.empty
    else hash

search :: ByteString -> Map.Map ByteString [RawFilePath] -> Set.Set RawFilePath -> Set.Set RawFilePath
search bytes table initial = go 0 initial
  where
    limit = B.length bytes - 32
    go i found
      | i > limit = found
      | otherwise =
          let candidate = B.take 32 (B.drop i bytes)
          in if B.all (`B.elem` base32Alphabet) candidate
            then case Map.lookup candidate table of
              Just paths -> go (i + 1) (foldr Set.insert found paths)
              Nothing -> go (i + 1) found
            else go (i + 1) found

naiveReferences :: ByteString -> [RawFilePath] -> Set.Set RawFilePath
naiveReferences bytes candidates = Set.fromList
  [ path | path <- candidates, B.isInfixOf (referenceHash path) bytes ]
