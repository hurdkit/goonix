{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
-- A sandbox plan is immutable once its helper has been spawned.  The parser
-- round-trip uses the actual C++ parser; the boundary check rejects the old
-- KVM rewrite after c_spawn_sandbox.  This deliberately does not claim to
-- force the timing window that exposed the 10a8d4f01c1 race.
module Main (main) where

import Control.Monad (unless)
import Data.Bits ((.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Goonix.Build.Sandbox
import Control.Exception (bracket)
import System.Directory (createDirectory, removeDirectoryRecursive, getTemporaryDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..))
import System.Posix.Process (getProcessID)
import System.Process (rawSystem)

main :: IO ()
main = do
  [helper, source] <- getArgs
  let planBytes = encodeSandboxPlan SandboxPlan
        { planFlags = sandboxFlagUserNamespace .|. sandboxFlagSetIds .|.
            sandboxFlagMountNamespace .|. sandboxFlagNetworkNamespace .|.
            sandboxFlagPidNamespace .|. sandboxFlagIpcNamespace .|.
            sandboxFlagUtsNamespace .|. sandboxFlagChroot,
          planProgram = "/ignored", planArguments = ["/ignored"]
        , planEnvironment = [], planWorkingDirectory = "/ignored", planStdinFile = "/dev/null"
        , planUid = 0, planGid = 0, planStdinFd = maxBound, planLogFd = maxBound
        , planGroups = [], planCloseFds = [], planUidMapInside = 0, planUidMapOutside = 0
        , planGidMapInside = 0, planGidMapOutside = 0
        , planRoot = "/ignored", planStoreDirectory = "/ignored"
        , planHostname = "localhost", planDomainname = "(none)"
        , planMounts = [], planSeccomp = [], planSlirpProgram = "", planSlirpSeccomp = [] }
  parent <- getTemporaryDirectory
  pid <- getProcessID
  let directory = parent <> "/sandbox-plan-stable-" <> show pid
  bracket (createDirectory directory >> pure directory) removeDirectoryRecursive $ \directory -> do
    let path = directory <> "/plan"
    B.writeFile path planBytes
    parsed <- rawSystem helper ["--parse-plan", path]
    unless (parsed == ExitSuccess) (ioError (userError "real sandbox parser rejected a complete encoded plan"))
    B.writeFile path (B.take 4 planBytes)
    truncated <- rawSystem helper ["--parse-plan", path]
    unless (truncated /= ExitSuccess) (ioError (userError "parser accepted a truncated plan"))
  engine <- C.readFile source
  let writes = length (C.tails engine >>= \rest -> [() | C.isPrefixOf "B.writeFile (C.unpack planPath)" rest])
      (beforeSpawn, afterSpawn) = B.breakSubstring "result <- c_spawn_sandbox" engine
  putStrLn ("plan boundary: writes=" ++ show writes ++ ", post-spawn-write=" ++
    show (C.isInfixOf "B.writeFile (C.unpack planPath)" afterSpawn) ++ ", source=" ++ source)
  unless (writes == 1 && not (C.null afterSpawn)
      && C.isInfixOf "B.writeFile (C.unpack planPath)" beforeSpawn
      && not (C.isInfixOf "B.writeFile (C.unpack planPath)" afterSpawn)) $
    ioError (userError "sandbox plan must be written once before spawn and never rewritten after it")
  putStrLn "sandbox plan immutable after spawn: PASS"
