{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Hash
  ( HashAlgorithm (..)
  , Hash (..)
  , algorithmName
  , algorithmFromName
  , algorithmId
  , digestLength
  , hashBytes
  , hashBytesIO
  , hashFile
  , sha256
  , sha1
  , compressHash
  , HashSink
  , newHashSink
  , updateHashSink
  , finishHashSink
  ) where

import Control.Exception (bracketOnError, throwIO)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Char8 as C
import System.Posix.ByteString (RawFilePath)
import Data.Word (Word8)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.ForeignPtr (ForeignPtr, newForeignPtr, withForeignPtr)
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import System.IO (IOMode (ReadMode), withBinaryFile)
import Foreign.Storable (peek)
import System.IO.Unsafe (unsafePerformIO)

-- The numeric identifiers and names are libgcrypt's, as in libutil/hash.hh.
data HashAlgorithm = MD5 | SHA1 | SHA256 | SHA512 | SHA3_256 | SHA3_512 | BLAKE2S_256
  deriving (Eq, Ord, Show, Enum, Bounded)

data Hash = Hash { hashAlgorithm :: !HashAlgorithm, hashDigest :: !ByteString }
  deriving (Eq, Ord, Show)

algorithmName :: HashAlgorithm -> ByteString
algorithmName = \case
  MD5 -> "md5"; SHA1 -> "sha1"; SHA256 -> "sha256"; SHA512 -> "sha512"
  SHA3_256 -> "sha3-256"; SHA3_512 -> "sha3-512"; BLAKE2S_256 -> "blake2s-256"

algorithmFromName :: ByteString -> Either String HashAlgorithm
algorithmFromName name = case filter ((== name) . algorithmName) [minBound .. maxBound] of
  [algorithm] -> Right algorithm
  _ -> Left ("unknown hash algorithm: " ++ show name)

algorithmId :: HashAlgorithm -> CInt
algorithmId = \case
  MD5 -> 1; SHA1 -> 2; SHA256 -> 8; SHA512 -> 10
  SHA3_256 -> 313; SHA3_512 -> 315; BLAKE2S_256 -> 322

digestLength :: HashAlgorithm -> Int
digestLength = \case
  MD5 -> 16; SHA1 -> 20; SHA256 -> 32; SHA512 -> 64
  SHA3_256 -> 32; SHA3_512 -> 64; BLAKE2S_256 -> 32

foreign import ccall unsafe "gcry_check_version" c_check_version :: CString -> IO CString
foreign import ccall unsafe "gcry_md_get_algo_dlen" c_digest_length :: CInt -> IO CUInt
foreign import ccall unsafe "gcry_md_hash_buffer" c_hash_buffer :: CInt -> Ptr Word8 -> Ptr Word8 -> CSize -> IO ()
foreign import ccall unsafe "gcry_md_open" c_md_open :: Ptr (Ptr ()) -> CInt -> CUInt -> IO CInt
foreign import ccall unsafe "gcry_md_write" c_md_write :: Ptr () -> Ptr Word8 -> CSize -> IO ()
foreign import ccall unsafe "gcry_md_read" c_md_read :: Ptr () -> CInt -> IO (Ptr Word8)
foreign import ccall unsafe "&gcry_md_close" c_md_close :: FunPtr (Ptr () -> IO ())

sha256, sha1 :: ByteString -> ByteString
sha256 = hashBytes SHA256
sha1 = hashBytes SHA1

hashBytes :: HashAlgorithm -> ByteString -> ByteString
hashBytes algorithm input = unsafePerformIO (hashBytesIO algorithm input)
{-# NOINLINE hashBytes #-}

hashBytesIO :: HashAlgorithm -> ByteString -> IO ByteString
hashBytesIO algorithm input = do
  initialize
  len <- checkedDigestLength algorithm
  BI.create len $ \out -> B.useAsCStringLen input $ \(ptr, size) ->
    c_hash_buffer (algorithmId algorithm) out (castPtr ptr) (fromIntegral size)

hashFile :: HashAlgorithm -> RawFilePath -> IO Hash
hashFile algorithm path = withBinaryFile (C.unpack path) ReadMode $ \handle -> do
  sink <- newHashSink algorithm
  let loop = do
        bytes <- B.hGetSome handle 1048576
        if B.null bytes then finishHashSink sink else updateHashSink sink bytes >> loop
  loop

compressHash :: Int -> ByteString -> ByteString
compressHash size input = B.pack [foldl xor 0 [B.index input i | i <- [j, j + size .. B.length input - 1]] | j <- [0 .. size - 1]]

initialize :: IO ()
initialize = do
  version <- withCString "1.6.0" c_check_version
  if version == nullPtr then throwIO (userError "libgcrypt initialization failed") else pure ()

checkedDigestLength :: HashAlgorithm -> IO Int
checkedDigestLength algorithm = do
  actual <- fromIntegral <$> c_digest_length (algorithmId algorithm)
  if actual == digestLength algorithm then pure actual else throwIO (userError "unexpected libgcrypt digest length")

data HashSink = HashSink !HashAlgorithm !(ForeignPtr ())

newHashSink :: HashAlgorithm -> IO HashSink
newHashSink algorithm = do
  initialize
  bracketOnError (mallocBytes 8) free $ \handle -> do
    result <- c_md_open handle (algorithmId algorithm) 0
    if result /= 0 then throwIO (userError ("gcry_md_open failed: " ++ show result)) else do
      pointer <- peek handle
      if pointer == nullPtr then throwIO (userError "gcry_md_open returned null") else
        HashSink algorithm <$> newForeignPtr c_md_close pointer

updateHashSink :: HashSink -> ByteString -> IO ()
updateHashSink (HashSink _ handle) bytes = withForeignPtr handle $ \ptr ->
  B.useAsCStringLen bytes $ \(input, len) -> c_md_write ptr (castPtr input) (fromIntegral len)

finishHashSink :: HashSink -> IO Hash
finishHashSink (HashSink algorithm handle) = withForeignPtr handle $ \ptr -> do
  digest <- c_md_read ptr 0
  len <- checkedDigestLength algorithm
  bytes <- B.packCStringLen (castPtr digest, len)
  pure (Hash algorithm bytes)
