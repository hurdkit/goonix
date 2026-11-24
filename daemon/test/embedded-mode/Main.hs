-- Drive the HS materialiseGoonixFiles over the SAME embedded names as the C++
-- probe, so the verdicts and MESSAGE text can be diffed.
module Main (main) where

import Control.Exception (try, SomeException)
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import Goonix.Store.CaBuild (materialiseGoonixFiles)
import Goonix.Store.Derivation (Derivation (..))

names :: [String]
names = ["a", "a/b", "a/", "a//b", "/a", "", "a/./b", "a/../b", "./a",
         "..", "a\\b", "a/b/", "a/.", "a/..", "/", "a///", ".hidden",
         "a/b/c", "x/", "a//", "//a"]

main :: IO ()
main = do
  (dir:_) <- getArgs
  createDirectoryIfMissing True dir
  mapM_ (one dir) (zip [0 :: Int ..] names)
  where
    one dir (i, name) = do
      let bname = C.pack name
          drv = Derivation
            { outputs = Map.empty
            , inputDrvs = Map.empty
            , inputSrcs = Set.empty
            , platform = C.pack "x86_64-linux"
            , builder = C.pack "/bin/sh"
            , args = []
            , environment = Map.fromList
                [ (C.pack "__files", bname)
                , (C.pack "__file:" <> bname, C.pack "content") ]
            }
          host = C.pack (dir ++ "/host-" ++ show i)
          sandbox = C.pack "/build"
          args = [C.pack "$NIX_BUILD_TOP/" <> bname]
      createDirectoryIfMissing True (C.unpack host)
      r <- try (materialiseGoonixFiles drv args host sandbox) :: IO (Either SomeException [C.ByteString])
      let verdict = case r of
            Right _ -> "OK"
            Left e  -> "ERROR " ++ show e
      putStrLn ("name=\"" ++ name ++ "\" " ++ verdict)