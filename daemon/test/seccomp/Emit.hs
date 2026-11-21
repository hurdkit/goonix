module Main where
import qualified Data.ByteString as B
import Goonix.Build.Seccomp (encodeInstructions, nativeArchitecture, slirpSeccompFilter)
main :: IO ()
main = B.putStr (encodeInstructions (slirpSeccompFilter nativeArchitecture))
