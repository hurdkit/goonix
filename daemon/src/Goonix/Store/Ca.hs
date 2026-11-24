{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | goonix content addressing (HS-11, CA-0): tokens, placeholders, reserved
-- paths, addressing modes, the canonical tree hash and content/resolved store
-- paths.  Ported from the verified C++ nix/libstore/ca.cc; the shared vectors
-- (tests/ca-vectors.json) are the reference.  Domains and byte framing match the
-- C++ exactly: goonix-tree-v1\0, goonix-content-v1\0, goonix:self-token:v1:,
-- goonix:placeholder:v1:, alphabet "eout", little-endian 64-bit length prefixes.
module Goonix.Store.Ca
  ( Addressing (..)
  , selfToken
  , tokenPath
  , makePlaceholder
  , isReservedStorePath
  , isPlaceholderPath
  , isTokenStorePath
  , assertNotReserved
  , validateTokenPath
  , addressingOf
  , goonixAddressed
  , resolvedDerivation
  , treeHash
  , contentAddressedPath
  , resolvedAddressedPath
  , encodeReserved
  , reservedHashPart
  , nukeMarker
  , put64
  , putBytes
  , treeDomain
  , contentDomain
  ) where

import Data.Bits ((.&.), shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.List (sort)
import Data.Word (Word64)
import Goonix.Store.Files (directoryEntries)
import Goonix.Store.Hash (Hash (..), HashAlgorithm (..), sha256, hashDigest)
import Goonix.Store.Path (makeStorePath, storePathToName)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Files.ByteString as Files

-- | The reserved alphabet, as in C++ ca.cc.
alphabet :: ByteString
alphabet = "eout"

-- | Upstream's remove-store-references (guix/build/utils.scm:1329) writes 32 'e'
-- characters followed by '-' as its nuke-refs marker, into every file it
-- processes and into every output that ships Guix's build modules.  That string
-- must never be a goonix name, so it is not reserved.  To keep the exemption
-- sound rather than fail-open, encodeReserved bumps a placeholder's last
-- character to 'o' when all 31 encoded characters would be 'e': no placeholder
-- can then be that string.  The cost is that one digest shares its name with the
-- digest encoding to e...eo, a 2^-62 collision - the same order as the collision
-- 62 bits already allow between any two placeholders.  Tokens start with 'o',
-- 'u' or 't' and are unaffected.  Keep in step with reserved-hash in guix/ca.scm
-- and nukeMarker / encodeReserved in nix/libstore/ca.cc.
nukeMarker :: ByteString
nukeMarker = B.replicate 32 101 -- 32 'e'

treeDomain, contentDomain :: ByteString
treeDomain = "goonix-tree-v1\0"
contentDomain = "goonix-content-v1\0"

-- | Little-endian 64-bit length prefix (C++ put64).
put64 :: Word64 -> ByteString
put64 value = B.pack [fromIntegral (value `shiftR` (i * 8)) .&. 0xff | i <- [0 .. 7]]

-- | A framed byte field: 64-bit length then exactly that many bytes (C++ putBytes).
putBytes :: ByteString -> ByteString
putBytes bytes = put64 (fromIntegral (B.length bytes)) <> bytes

-- | The 32-character reserved encoding of a SHA-256 digest (C++ encodeReserved).
-- The first character is 'e' for a placeholder, or alphabet[1 + digest[0] % 3]
-- for a token; the remaining 31 characters read 2-bit groups of the digest
-- starting at bit 2, most-significant pair first within each byte.
encodeReserved :: ByteString -> Bool -> ByteString
encodeReserved digest token =
  let first = if token
        then B.index alphabet (1 + fromIntegral (B.index digest 0) `mod` 3)
        else 101 -- 'e'
      rest = [ B.index alphabet (fromIntegral (pair i)) | i <- [1 .. 31] ]
      pair i =
        let bit = 2 + 2 * (i - 1)
            byte = B.index digest (bit `div` 8)
        in (byte `shiftR` (6 - bit `mod` 8)) .&. 3
      result = B.pack (first : rest)
  in if not token && result == nukeMarker
       then B.pack (B.unpack (B.take 31 result) ++ [111]) -- last char 'o'
       else result

checkOutputName :: ByteString -> Either String ()
checkOutputName name
  | B.null name = Left ("invalid CA output name `" ++ C.unpack name ++ "'")
  | B.elem 47 name = Left ("invalid CA output name `" ++ C.unpack name ++ "'")
  | B.index name 0 == 46 = Left ("invalid CA output name `" ++ C.unpack name ++ "'")
  | Just c <- B.find (\c -> not ((c >= 65 && c <= 90) || (c >= 97 && c <= 122)
      || (c >= 48 && c <= 57) || c `B.elem` "+-._?=")) name =
      Left ("invalid CA output name `" ++ C.unpack name ++ "'")
  | otherwise = Right ()

-- | The self token of an output (C++ selfToken).
selfToken :: ByteString -> ByteString
selfToken output = case checkOutputName output of
  Left err -> error err
  Right () -> encodeReserved (sha256 ("goonix:self-token:v1:" <> output)) True

-- | The token store path of an output (C++ tokenPath).
tokenPath :: ByteString -> ByteString -> ByteString -> ByteString
tokenPath store output name = store <> "/" <> selfToken output <> "-" <> name

-- | The placeholder path of an unresolved derivation/output (C++ makePlaceholder).
makePlaceholder :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString
makePlaceholder store unresolvedBytes output name = case checkOutputName output of
  Left err -> error err
  Right () ->
    let prefix = "goonix:placeholder:v1:" <> C.pack (show (B.length unresolvedBytes))
          <> ":" <> output <> ":"
    in store <> "/" <> encodeReserved (sha256 (prefix <> unresolvedBytes)) False <> "-" <> name

-- | The one shared predicate (C++ reservedHashPart): a reserved hash part is 32
-- characters of the reserved alphabet, EXCEPT upstream's nuke-refs marker (see
-- nukeMarker above), which is ordinary upstream data and never a goonix name.
-- Every site that decides "reserved" goes through this — the path predicate,
-- the placeholder and token checks, the refusal of reserved names in requests,
-- and the output scan (Goonix.Store.CaBuild.checkReserved).
reservedHashPart :: ByteString -> Bool
reservedHashPart part =
  B.length part == 32
  && B.all (\c -> c `B.elem` alphabet) part
  && part /= nukeMarker

-- | A reserved path is a store path whose 32-character hash part uses only the
-- reserved alphabet (C++ reservedPath).  C++ uses baseNameOf (the full
-- basename, hash included), NOT storePathToName (which strips the hash).
reservedPath :: ByteString -> ByteString -> Bool
reservedPath store path =
  let base = baseNameOf path
      hashPart = B.take 32 base
  in isStorePath store path
     && B.length path >= B.length store + 35
     && B.length base >= 34
     && B.index base 32 == 45 -- '-'
     && reservedHashPart hashPart

baseNameOf :: ByteString -> ByteString
baseNameOf = snd . C.breakEnd (== '/')

isStorePath :: ByteString -> ByteString -> Bool
isStorePath store path =
  B.length path > B.length store + 1
  && B.take (B.length store + 1) path == store <> "/"

isReservedStorePath :: ByteString -> ByteString -> Bool
isReservedStorePath = reservedPath

isPlaceholderPath :: ByteString -> ByteString -> Bool
isPlaceholderPath store path =
  reservedPath store path && B.index (baseNameOf path) 0 == 101 -- 'e'

isTokenStorePath :: ByteString -> ByteString -> Bool
isTokenStorePath store path =
  reservedPath store path && B.index (baseNameOf path) 0 /= 101

assertNotReserved :: ByteString -> ByteString -> Either String ()
assertNotReserved store path
  | reservedPath store path =
      Left ("refusing unresolved goonix token or placeholder `" ++ C.unpack path ++ "'")
  | otherwise = Right ()

validateTokenPath :: ByteString -> ByteString -> Either String ByteString
validateTokenPath store path
  | isTokenStorePath store path = Right path
  | isTokenStorePath store (store <> "/" <> path) = Right path
  | otherwise = Left ("invalid goonix self token `" ++ C.unpack path ++ "'")

-- | The addressing mode of a derivation, from its goonixAddressing environment
-- entry (C++ addressingOf).  The derivation is represented by its environment
-- map here; the full Derivation integration lives in the engine port.
data Addressing = Input | Content | Resolved deriving (Eq, Show)

addressingOfEnv :: ByteString -> Either String Addressing
addressingOfEnv value
  | value == "content" = Right Content
  | value == "resolved" = Right Resolved
  | otherwise = Left ("unknown goonix addressing `" ++ C.unpack value ++ "'")

-- | addressingOf over an environment lookup (Nothing = input-addressed).
addressingOf :: Maybe ByteString -> Either String Addressing
addressingOf Nothing = Right Input
addressingOf (Just value) = addressingOfEnv value

goonixAddressed :: Maybe ByteString -> Bool
goonixAddressed env = case addressingOf env of
  Right Input -> False
  Right _ -> True
  Left _ -> True

resolvedDerivation :: Maybe ByteString -> Bool
resolvedDerivation (Just "1") = True
resolvedDerivation _ = False

-- | The canonical tree hash of a filesystem tree (C++ treeHash / hashTree).
-- Regular file: treeDomain + 1 + executable marker + framed (length, bytes),
-- hashed with SHA-256.  Symlink: treeDomain + 2 + framed target.  Directory:
-- treeDomain + 3 + framed entry count, then for each entry in byte-sorted name
-- order: framed name + framed child hex hash.  Nesting is capped at 1024.
treeHash :: RawFilePath -> IO Hash
treeHash path = hashTree path 0

hashTree :: RawFilePath -> Int -> IO Hash
hashTree path depth
  | depth > 1024 = ioError (userError "CA tree nesting exceeds 1024 directories")
  | otherwise = do
      status <- Files.getSymbolicLinkStatus path
      if Files.isRegularFile status
        then do
          let executable = if Files.fileMode status .&. 0o100 /= 0 then 1 else 0
              header = treeDomain <> B.pack [1, executable]
          contents <- B.readFile (C.unpack path)
          let framed = header <> put64 (fromIntegral (B.length contents)) <> contents
          pure (Hash SHA256 (sha256 framed))
        else if Files.isSymbolicLink status
          then do
            target <- Files.readSymbolicLink path
            pure (Hash SHA256 (sha256 (treeDomain <> B.pack [2] <> putBytes target)))
          else if Files.isDirectory status
            then do
              entries <- listDirectorySorted path
              let count = put64 (fromIntegral (length entries))
              parts <- mapM (entryEncoding path) entries
              pure (Hash SHA256 (sha256 (treeDomain <> B.pack [3] <> count <> B.concat parts)))
            else ioError (userError ("unsupported file type in CA tree `" ++ C.unpack path ++ "'"))
  where
    entryEncoding dir name = do
      child <- hashTree (dir <> "/" <> name) (depth + 1)
      pure (putBytes name <> putBytes (printHash child))

-- | Lowercase base-16 of a hash (C++ printHash).
printHash :: Hash -> ByteString
printHash = encodeBase16 . hashDigest
  where
    encodeBase16 = B.concatMap (\w -> B.pack [hexChar (w `shiftR` 4), hexChar (w .&. 0x0f)])
    hexChar n = if n < 10 then 48 + n else 87 + n

-- | Sorted directory entry names, byte order (C++ readDirectory + sort).
listDirectorySorted :: RawFilePath -> IO [ByteString]
listDirectorySorted path = sort <$> directoryEntries path

-- | The content-addressed store path of an output (C++ contentAddressedPath).
contentAddressedPath :: ByteString -> ByteString -> ByteString -> Hash -> [ByteString] -> ByteString
contentAddressedPath store output name tree references =
  let bytes = contentDomain <> putBytes (hashDigest tree)
        <> put64 (fromIntegral (length references))
        <> B.concat (map putBytes (sort references))
  in makeStorePath store ("goonix-content:" <> output) (sha256 bytes) name

-- | The resolved-addressed store path of an output (C++ resolvedAddressedPath).
resolvedAddressedPath :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString
resolvedAddressedPath store output name resolvedBytes =
  makeStorePath store ("goonix-resolved:" <> output) (sha256 resolvedBytes) name