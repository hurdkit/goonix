{-# LANGUAGE GHC2024 #-}

-- Copy real derivations into immutable vector inputs.  NAR vectors are
-- produced by the companion store dumper, not by copying file contents.

module Main (main) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.List (isSuffixOf)
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.Environment (getArgs)
import System.FilePath ((</>), takeDirectory)

main :: IO ()
main = getArgs >>= \case
    [store, output] -> generate store output
    _ -> fail "usage: Generate STORE OUTPUT-DIRECTORY"

generate :: FilePath -> FilePath -> IO ()
generate store output = do
    entries <- listDirectory store
    let derivations = filter (".drv" `isSuffixOf`) entries
    forM_ derivations $ \entry -> do
        let target = output </> "derivations" </> entry
        createDirectoryIfMissing True (takeDirectory target)
        BS.readFile (store </> entry) >>= BS.writeFile target
