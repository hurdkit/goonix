{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
import Goonix.Store.ReadOnly
import Goonix.Store.Database
import qualified Goonix.Config as Config
import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as C
import System.Environment (getArgs)
main = getArgs >>= \[db, store] -> withReadOnly db $ \_ -> do
  s <- openStore (C.pack store) db (C.pack Config.stateDirectory)
  paths <- queryAllValidPaths s
  forM_ paths C.putStrLn
  closeStore s
