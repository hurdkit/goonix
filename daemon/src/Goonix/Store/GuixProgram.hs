{-# LANGUAGE OverloadedStrings #-}

-- | goonix: the one resolution of the guix program (HS-8 switch-2 CI fix).
-- The C++ daemon never searches PATH: globals.cc processEnvironment sets
-- @guixProgram = canonPath(getEnv("GUIX", nixBinDir + "/guix"))@ with
-- @nixBinDir = canonPath(getEnv("NIX_BIN_DIR", NIX_BIN_DIR))@, and every agent
-- (builtin download, authenticate, substituter, offload, discover, gc
-- --list-busy) uses settings.guixProgram.  A CI runner starts the daemon with
-- no GUIX and no guix on PATH, so a literal "guix" fallback fails the first
-- builtin:git-download build.  This module resolves the program once, exactly
-- as C++ does, and every spawn site uses it.
module Goonix.Store.GuixProgram
  ( guixProgram
  , canonPath
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Goonix.Config as Config
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Env.ByteString (getEnv)

-- | Resolved once per process, like the C++ settings.guixProgram computed in
-- processEnvironment at start-up.  The daemon's environment does not change
-- after start-up, so caching is equivalent to resolving at every spawn.
{-# NOINLINE guixProgramCache #-}
guixProgramCache :: IORef (Maybe B.ByteString)
guixProgramCache = unsafePerformIO (newIORef Nothing)

-- | GUIX if set, else NIX_BIN_DIR if set, else the configured bindir, plus
-- "/guix", made canonical (C++ Settings::processEnvironment).
guixProgram :: IO B.ByteString
guixProgram = do
  cached <- readIORef guixProgramCache
  case cached of
    Just program -> pure program
    Nothing -> do
      guix <- getEnv "GUIX"
      nixBinDir <- getEnv "NIX_BIN_DIR"
      let binDir = canonPath (case nixBinDir of
            Just dir | not (B.null dir) -> dir
            _ -> C.pack Config.binaryDirectory)
          program = canonPath (case guix of
            Just path | not (B.null path) -> path
            _ -> binDir <> "/guix")
      writeIORef guixProgramCache (Just program)
      pure program

-- | C++ canonPath (util.cc, resolveSymlinks = false): require an absolute
-- path, collapse repeated slashes, drop "." components and resolve ".."
-- against the preceding component.  Symlinks are NOT resolved (the default).
canonPath :: B.ByteString -> B.ByteString
canonPath path
  | B.null path || B.index path 0 /= 47 =
      error ("not an absolute path: `" ++ C.unpack path ++ "'")
  | otherwise = "/" <> B.intercalate "/" (foldl step [] (C.split '/' path))
  where
    step acc "" = acc
    step acc "." = acc
    step acc ".." = if null acc then [] else init acc
    step acc component = acc ++ [component]