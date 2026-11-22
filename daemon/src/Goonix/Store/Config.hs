{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
module Goonix.Store.Config
  ( ServerConfig (..)
  , defaultConfig
  ) where
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import qualified Goonix.Config as Config
import Goonix.Store.Settings (Settings, defaultSettings)
import Goonix.Build.Users (UserPool, loadUserPool)
import Goonix.Build.Shared (Shared)

data ServerConfig = ServerConfig
  { configStore :: !ByteString
  , configDatabase :: !FilePath
  , configDefaultSettings :: !Settings
  , configLogConnections :: !Bool
  , configReadOnly :: !Bool
  , configStateDirectory :: !(Maybe ByteString)
  , configGuixProgram :: !ByteString
  , configBuildUsers :: !(Maybe UserPool)
  , configSharedScheduler :: !(Maybe Shared)
  -- ^ HS-12: the process-wide shared scheduler (one job limit, one goal per
  -- derivation across clients).  Nothing for a standalone per-request build.
  }

defaultConfig :: ServerConfig
defaultConfig = ServerConfig "/gnu/store" "/var/guix/db/db.sqlite"
  (defaultSettings True False) False True Nothing (C.pack (Config.binaryDirectory ++ "/guix")) Nothing Nothing
