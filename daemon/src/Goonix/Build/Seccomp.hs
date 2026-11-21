{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}

-- Linux seccomp policy for slirp4netns.  Instruction construction follows
-- nix/libutil/seccomp.cc and build.cc, including the binary search over
-- pinned syscall ranges.
module Goonix.Build.Seccomp
  ( Instruction
  , Architecture (..)
  , nativeArchitecture
  , slirpSeccompFilter
  , encodeInstructions
  , rangeActionsToFilter
  , matchWord64
  , RangeAction (..)
  ) where

import Data.Bits (shiftR, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.List (sortOn)
import Data.Word (Word32, Word64)

-- code, jt, jf, k: struct sock_filter widened for the sandbox plan.
type Instruction = (Word32, Word32, Word32, Word32)
data Architecture = X86_64 | Aarch64 deriving (Eq, Show)
data RangeAction = RangeAction Word32 Word32 [Instruction]
data Pending = Pending Instruction Bool Bool Bool

nativeArchitecture :: Architecture
#if defined(x86_64_HOST_ARCH)
nativeArchitecture = X86_64
#elif defined(aarch64_HOST_ARCH)
nativeArchitecture = Aarch64
#else
#error "HS-6 seccomp policy is only defined for x86_64 and aarch64"
#endif

statement :: Word32 -> Word32 -> Instruction
statement code constant = (code, 0, 0, constant)

ldAbs, ret, jeq, jge, jgt, ja :: Word32
ldAbs = 0x20
ret = 0x06
jeq = 0x15
jge = 0x35
jgt = 0x25
ja = 0x05

allow, deny, silentDeny :: Instruction
allow = statement ret 0x7fff0000
deny = statement ret (0x00050000 .|. 38) -- SECCOMP_RET_ERRNO | ENOSYS
silentDeny = statement ret 0x00050000

architectureConstant :: Architecture -> Word32
architectureConstant X86_64 = 0xc000003e -- AUDIT_ARCH_X86_64
architectureConstant Aarch64 = 0xc00000b7 -- AUDIT_ARCH_AARCH64

nativeSyscallRanges :: Architecture -> [(Word32, Word32)]
nativeSyscallRanges X86_64 = [(0, 335), (424, 466)]
nativeSyscallRanges Aarch64 = [(0, 243), (260, 294), (424, 466)]

socketSyscall, socketpairSyscall, ptraceSyscall :: Architecture -> Word32
socketSyscall X86_64 = 41
socketSyscall Aarch64 = 198
socketpairSyscall X86_64 = 53
socketpairSyscall Aarch64 = 199
ptraceSyscall X86_64 = 101
ptraceSyscall Aarch64 = 117

-- struct seccomp_data: nr=0, arch=4, args[0]=16.
slirpSeccompFilter :: Architecture -> [Instruction]
slirpSeccompFilter architecture =
  [statement ldAbs 4, (jeq, 1, 0, architectureConstant architecture), deny] ++
  [statement ldAbs 0] ++ specialCases ++ [statement ldAbs 0] ++ pinnedWhitelist ++ [deny]
  where
    allowInet = matchWord64 [] 2 [allow] 16 ++ matchWord64 [] 10 [allow] 16
    denyNonInet = allowInet ++ [deny]
    silentDenyNonInet = allowInet ++ [silentDeny]
    specialCases = rangeActionsToFilter
      [ RangeAction n n action
      | (n, action) <-
          [ (socketSyscall architecture, denyNonInet)
          , (socketpairSyscall architecture, silentDenyNonInet)
          , (ptraceSyscall architecture, [deny])
          ]
      ]
    pinnedWhitelist = rangeActionsToFilter
      [RangeAction low high [allow] | (low, high) <- nativeSyscallRanges architecture]

-- Append a little-endian uint64 comparison and set the false branches to the
-- instruction following the appended body.  This is seccompMatchu64 verbatim.
matchWord64 :: [Instruction] -> Word64 -> [Instruction] -> Word32 -> [Instruction]
matchWord64 prefix value instructions offset = prefix ++
  [ statement ldAbs offset
  , (jeq, 0, fromIntegral (length instructions + 2), low)
  , statement ldAbs (offset + 4)
  , (jeq, 0, fromIntegral (length instructions), high)
  ] ++ instructions
  where
    low = fromIntegral value
    high = fromIntegral (value `shiftR` 32)

-- A direct structural translation of rangeActionsToFilter.  Returning the
-- patched output vector avoids using evaluation-order tricks to emulate C++.
rangeActionsToFilter :: [RangeAction] -> [Instruction]
rangeActionsToFilter [] = []
rangeActionsToFilter (first:rest)
  | any (\(RangeAction low high _) -> low > high) ordered = error "invalid seccomp syscall range"
  | any (\(RangeAction _ high _, RangeAction low _ _) -> low <= high) (zip ordered (drop 1 ordered)) =
      error "overlapping seccomp syscall ranges"
  | otherwise = map resolve (zip [0 ..] output)
  where
    ordered = sortOn (\(RangeAction low _ _) -> low) (first:rest)
    RangeAction firstLow _ _ = first
    output = snd (generate ordered 0 (length ordered) [Pending (jge, 0, 0, firstLow) False True False])
    generate _ low end accumulated | low >= end = (length accumulated, accumulated)
    generate rs low end accumulated | end == low + 1 =
      let RangeAction _ high instructions = rs !! low
          withBranch = accumulated ++ [Pending (jgt, 0, 0, high) True False False]
          withActions = withBranch ++ map (\instruction -> Pending instruction False False False) instructions
      in (length withActions, withActions ++ [Pending (ja, 0, 0, 0) False False True])
    generate rs low end accumulated =
      let middle = low + (end - low) `div` 2
          RangeAction middleLow _ _ = rs !! middle
          branch = length accumulated
          (_, right) = generate rs middle end
            (accumulated ++ [Pending (jge, 0, 0, middleLow) False False False])
          elseIndex = length right
          patched = patchJump branch (fromIntegral (elseIndex - branch - 1)) right
      in generate rs low middle patched
    patchJump index distance items =
      let Pending (code, jt, _, k) patchJt patchJf patchK = items !! index
      in take index items ++ [Pending (code, jt, distance, k) patchJt patchJf patchK] ++ drop (index + 1) items
    fallthrough = length output
    resolve (index, Pending (code, oldJt, oldJf, oldK) patchJt patchJf patchK) =
      let distance = fromIntegral (fallthrough - index - 1)
      in (code, if patchJt then distance else oldJt,
          if patchJf then distance else oldJf, if patchK then distance else oldK)

encodeInstructions :: [Instruction] -> ByteString
encodeInstructions = foldMap $ \(code, jt, jf, k) -> foldMap u32 [code, jt, jf, k]
  where
    u32 value = B.pack [fromIntegral (value `div` (256 ^ index)) | index <- [0 .. 3 :: Int]]
