{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- Byte-oriented plans executed by the external guix-sandbox helper.  No
-- Haskell code runs between fork and exec: descriptor setup belongs to C.
module Goonix.Build.Sandbox
  ( SandboxPlan (..)
  , BindMount (..)
  , encodeSandboxPlan
  , sandboxFlagSetIds
  , sandboxFlagSetSid
  , sandboxFlagCloseFds
  , sandboxFlagChdir
  , sandboxFlagStdinFile
  , sandboxFlagClearGroups
  , sandboxFlagNoNewPrivs
  , sandboxFlagRedirectLog
  , sandboxFlagUserNamespace
  , sandboxFlagHostIdentities
  , sandboxFlagMountNamespace
  , sandboxFlagNetworkNamespace
  , sandboxFlagPidNamespace
  , sandboxFlagIpcNamespace
  , sandboxFlagUtsNamespace
  , sandboxFlagChroot
  , sandboxFlagProc
  , sandboxFlagDevpts
  , sandboxFlagLockMounts
  , sandboxFlagSlirpNetwork
  , sandboxFlagIsolateHostLoopback
  , sandboxFlagIpv6Network
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word (Word32, Word64)

data BindMount = BindMount
  { mountSource :: !ByteString
  , mountTarget :: !ByteString
  , mountReadOnly :: !Bool
  } deriving (Eq, Show)

data SandboxPlan = SandboxPlan
  { planFlags :: !Word64
  , planProgram :: !ByteString
  , planArguments :: ![ByteString]
  , planEnvironment :: ![(ByteString, ByteString)]
  , planWorkingDirectory :: !ByteString
  , planStdinFile :: !ByteString
  , planUid :: !Word32
  , planGid :: !Word32
  , planStdinFd :: !Word32
  , planLogFd :: !Word32
  , planGroups :: ![Word32]
  , planCloseFds :: ![Word32]
  , planUidMapInside :: !Word32
  , planUidMapOutside :: !Word32
  , planGidMapInside :: !Word32
  , planGidMapOutside :: !Word32
  , planRoot :: !ByteString
  , planStoreDirectory :: !ByteString
  , planHostname :: !ByteString
  , planDomainname :: !ByteString
  , planMounts :: ![BindMount]
  , planSeccomp :: ![(Word32, Word32, Word32, Word32)]
  , planSlirpProgram :: !ByteString
  , planSlirpSeccomp :: ![(Word32, Word32, Word32, Word32)]
  } deriving (Eq, Show)

sandboxFlagSetIds, sandboxFlagSetSid, sandboxFlagCloseFds,
  sandboxFlagChdir, sandboxFlagStdinFile, sandboxFlagClearGroups,
  sandboxFlagNoNewPrivs, sandboxFlagRedirectLog,
  sandboxFlagUserNamespace, sandboxFlagHostIdentities, sandboxFlagMountNamespace,
  sandboxFlagNetworkNamespace, sandboxFlagPidNamespace,
  sandboxFlagIpcNamespace, sandboxFlagUtsNamespace, sandboxFlagChroot,
  sandboxFlagProc, sandboxFlagDevpts, sandboxFlagLockMounts,
  sandboxFlagSlirpNetwork, sandboxFlagIsolateHostLoopback,
  sandboxFlagIpv6Network :: Word64
sandboxFlagSetIds = 1
sandboxFlagSetSid = 2
sandboxFlagCloseFds = 4
sandboxFlagChdir = 32
sandboxFlagStdinFile = 64
sandboxFlagClearGroups = 256
sandboxFlagNoNewPrivs = 512
sandboxFlagRedirectLog = 2048
sandboxFlagUserNamespace = 4096
sandboxFlagMountNamespace = 8192
sandboxFlagNetworkNamespace = 16384
sandboxFlagPidNamespace = 32768
sandboxFlagIpcNamespace = 65536
sandboxFlagUtsNamespace = 131072
sandboxFlagChroot = 262144
sandboxFlagProc = 524288
sandboxFlagDevpts = 1048576
sandboxFlagLockMounts = 2097152
sandboxFlagSlirpNetwork = 4194304
sandboxFlagIsolateHostLoopback = 8388608
sandboxFlagIpv6Network = 16777216
-- Root + leased user: private non-user namespaces and real setgroups/setgid/
-- setuid.  Unprivileged builds leave this clear and retain their UID/GID map.
sandboxFlagHostIdentities = 33554432

encodeSandboxPlan :: SandboxPlan -> ByteString
encodeSandboxPlan plan = B.concat
  [ "GSP0002\0"
  , u64 (planFlags plan)
  , string (planProgram plan)
  , list string (planArguments plan)
  , list pair (planEnvironment plan)
  , string (planWorkingDirectory plan)
  , string (planStdinFile plan)
  , u32 (planUid plan), u32 (planGid plan)
  , u32 (planStdinFd plan), u32 (planLogFd plan)
  , list u32 (planGroups plan)
  , list u32 (planCloseFds plan)
  , u32 (planUidMapInside plan), u32 (planUidMapOutside plan)
  , u32 (planGidMapInside plan), u32 (planGidMapOutside plan)
  , string (planRoot plan), string (planStoreDirectory plan), string (planHostname plan), string (planDomainname plan)
  , list mount (planMounts plan)
  , list seccomp (planSeccomp plan)
  , string (planSlirpProgram plan)
  , list seccomp (planSlirpSeccomp plan)
  ]
  where
    pair (name, value) = string name <> string value
    mount (BindMount source target readOnly) =
      string source <> string target <> u32 (if readOnly then 1 else 0)
    seccomp (code, jumpTrue, jumpFalse, constant) =
      u32 code <> u32 jumpTrue <> u32 jumpFalse <> u32 constant

list :: (a -> ByteString) -> [a] -> ByteString
list encode values = u32 (fromIntegral (length values)) <> foldMap encode values

string :: ByteString -> ByteString
string bytes = u32 (fromIntegral (B.length bytes)) <> bytes

u32 :: Word32 -> ByteString
u32 value = B.pack [fromIntegral (value `div` (256 ^ index)) | index <- [0 .. 3 :: Int]]

u64 :: Word64 -> ByteString
u64 value = B.pack [fromIntegral (value `div` (256 ^ index)) | index <- [0 .. 7 :: Int]]
