{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Main (main) where

import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Goonix.Build.Offload
import System.Environment (getArgs)
import System.IO (hGetLine, hIsEOF)
import System.Posix.Env.ByteString (getEnv)

main :: IO ()
main = do
  args <- getArgs
  program <- maybe "/bin/false" id <$> getEnv "GOONIX_OFFLOAD_PROGRAM"
  bracket (startOffloadHook program "x86_64-linux" 7 True 11) stopHook $ \hook -> do
    reply <- requestOffload hook True "x86_64-linux" "/gnu/store/example.drv" ["kvm"]
    reply @?= HookDecline
    putStrLn "offload decline transcript passed"

(@?=) :: (Eq a, Show a) => a -> a -> IO ()
actual @?= expected = unless (actual == expected) (throwIO (userError ("expected " ++ show expected ++ ", got " ++ show actual)))
