{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
import Goonix.Store.Files (readTemporaryRootFile, writeBytes)
import Control.Exception (IOException, catch)
import Control.Monad (unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import System.Environment (getArgs)
import System.Posix.IO.ByteString (OpenMode (ReadOnly), defaultFileFlags, openFd)
import System.Posix.Types (Fd (..))

main :: IO ()
main = do
  [argument] <- getArgs
  let path = C.pack argument
  let paths = [C.pack ("/tmp/goonix-reader-" ++ show index ++ "-" ++ replicate 100 (toEnum (fromEnum 'a' + index `mod` 26))) | index <- [0 .. 3000 :: Int]]
      payload = B.concat (map (<> "\0") paths)
  writeBytes path payload
  unless (B.length payload > 65536 * 4) (error "fixture does not cross read chunks")
  Fd fd <- openFd path ReadOnly defaultFileFlags
  actual <- readTemporaryRootFile (Fd fd)
  unless (actual == paths) (error "temporary roots differ from fixture")
  -- Invalid descriptors return EBADF; they must not be treated as EOF or lengths.
  failed <- (readTemporaryRootFile (Fd (-1)) >> pure False) `catch` \(_ :: IOError) -> pure True
  unless failed (error "invalid descriptor was accepted")
  putStrLn ("temporary-root reader: PASS (" ++ show (B.length payload) ++ " bytes, " ++ show (length paths) ++ " paths)")
