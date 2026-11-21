{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- The engine interprets Goonix.Build.Scheduler.  Pure step calls choose all
-- starts and failures; IO threads only execute jobs and report their events.
module Goonix.Build.Engine
  ( BuildMode (..)
  , buildThings
  , buildThingsWithTrace
  , buildThingsWithConfig
  , buildThingsWithCancel
  , ensureStorePath
  , BuildTrace (..)
  ) where

import Control.Concurrent (forkIO, threadDelay, killThread)
import Control.Concurrent.MVar (newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Concurrent.STM (STM, atomically, newEmptyTMVarIO, orElse, putTMVar, readTMVar, registerDelay, takeTMVar)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, atomicWriteIORef, atomicModifyIORef')
import Data.Time.Clock.POSIX (POSIXTime)
import Control.Exception (IOException, SomeException, bracket, bracketOnError, catch, finally, fromException, mask, onException, throwIO, try)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Monad ((>=>), foldM, forM, forM_, replicateM_, unless, void, when)
import Data.Bits ((.|.))
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32)
import Goonix.Store.Base32 (decodeBase16, decodeBase32, encodeBase32)
import Goonix.Store.Derivation
import Goonix.Store.Files
import Goonix.Store.Hash
import Goonix.Store.Nar (dumpNar, hashNar)
import Goonix.Store.Archive (rewriteNarPaths)
import Goonix.Store.Path (storePathToName)
import Goonix.Store.ReadOnly
import Goonix.Store.References (scanReferences)
import Goonix.Store.Settings
import Goonix.Store.Config (ServerConfig, configGuixProgram, configBuildUsers, configSharedScheduler, configStore, configDatabase, configStateDirectory)
import Goonix.Store.Substitute (substitutableInfos, substitutePath)
import Goonix.Store.Writing
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Directory.ByteString as Dir
import qualified System.Posix.Files.ByteString as Files
import System.Exit (ExitCode (ExitSuccess, ExitFailure))
import System.IO (Handle, hClose, hPutStrLn, stderr)
import System.Process (CreateProcess (..), CmdSpec (..), StdStream (..), createProcess, getPid, proc, waitForProcess)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (fileOwner, fileGroup)
import System.Posix.Process (getProcessID, getProcessStatus, ProcessStatus (Exited, Terminated, Stopped))
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Posix.IO.ByteString (createPipe, fdToHandle)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID)
import System.FilePath (takeDirectory)
import System.Directory (findExecutable)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError)
import System.Posix.Types (Fd (..))
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)
import Goonix.Build.Sandbox
import Goonix.Build.Runtime (JobSpec (..), Outcome (..), runScheduled, runScheduledWithCancel, runScheduledShared)
import Goonix.Build.Scheduler (JobKind (..))
import Goonix.Build.Shared (raiseLimit, withGoal)
import Goonix.Build.Offload
import Goonix.Build.Users (BuildUser (..), UserPool, loadUserPool, withBuildUser)
import Goonix.Build.Seccomp (nativeArchitecture, slirpSeccompFilter)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Posix.Env.ByteString (getEnv)

data BuildMode = Normal | Repair | Check deriving (Eq, Show)
data BuildTrace = BuildTrace
  { traceStarted :: ByteString -> ByteString -> ByteString -> Int -> IO ()
  , traceSucceeded :: ByteString -> IO ()
  , traceFailed :: ByteString -> String -> IO ()
  , traceOutput :: ByteString -> IO ()
  }

buildThingsWithTrace :: Fd -> Store -> Settings -> BuildTrace -> [ByteString] -> BuildMode -> IO ()
buildThingsWithTrace rootFd store settings trace things mode =
  buildThingsInternal Nothing rootFd store settings trace Nothing things mode (pure ())

buildThingsWithConfig :: ServerConfig -> Fd -> Store -> Settings -> BuildTrace -> [ByteString] -> BuildMode -> IO ()
buildThingsWithConfig config rootFd store settings trace things mode =
  buildThingsWithCancel config rootFd store settings trace things mode (pure ())

buildThingsWithCancel :: ServerConfig -> Fd -> Store -> Settings -> BuildTrace -> [ByteString] -> BuildMode -> IO () -> IO ()
buildThingsWithCancel config rootFd store settings trace things mode cancel = do
  program <- if settingBool "build-use-build-hook" True settings then offloadProgram config else pure Nothing
  pool <- forM program $ \path -> do
    hook <- newIORef Nothing
    pure (hook, path)
  bracket (pure pool) (mapM_ (readIORef . fst >=> mapM_ stopHook)) $ \hooks ->
    buildThingsInternal (Just config) rootFd store settings trace hooks things mode cancel

downloadJobId :: ByteString -> ByteString
downloadJobId path = path <> "\0download"

type Dependency = (ByteString, Set.Set ByteString, JobKind)

type HookPool = (IORef (Maybe Hook), ByteString)

buildThingsInternal config rootFd store settings trace hook things mode cancel = do
  let userPool = config >>= configBuildUsers
  attemptedDownloads <- newIORef Set.empty
  -- C++ gives only the top-level goals the caller's build mode; the inputs of a
  -- derivation are built in normal mode unless the caller is repairing
  -- (DerivationGoal::haveDerivation).  A valid input in normal mode is done at
  -- once, so --check of a derivation rebuilds that derivation and nothing else.
  -- Passing the caller's mode to every job would rebuild valid inputs in check
  -- mode with redirected outputs (re-downloading fixed-output inputs, rebuilding
  -- the whole input closure), which C++ never does.
  let inputMode = if mode == Repair then Repair else Normal
  let discover jobMode path wanted role = case role of
        DownloadJob -> pure JobSpec
          { jobId = path, jobWanted = wanted, jobKind = DownloadJob
          , jobRun = \_ -> do
              let actualPath = B.take (B.length path - B.length "\0download") path
              case config of
                Just serverConfig -> void (trySubstitute serverConfig rootFd store settings trace actualPath)
                Nothing -> pure ()
              atomicModifyIORef' attemptedDownloads (\seen -> (Set.insert actualPath seen, ()))
              pure Done }
        BuildJob -> do
          phase <- newIORef False
          pure JobSpec
            { jobId = path, jobWanted = wanted, jobKind = BuildJob
            , jobRun = \requested -> do
                discovered <- readIORef phase
                if discovered
                  then do
                    -- HS-12: one goal per derivation across the clients of this
                    -- daemon.  The build runs in a daemon-owned thread that owns
                    -- its temporary roots and store handle and tolerates a gone
                    -- client, so it outlives the client that started it while any
                    -- other client is still interested (and is killed when the
                    -- last leaves).  The output locks still exclude other daemons.
                    --
                    -- Goals are shared only between NORMAL-mode requests.  A
                    -- Check or Repair request always runs its own build, as in
                    -- C++: attaching a check to a normal goal would check nothing,
                    -- and attaching a normal request to a check goal would take
                    -- "success" from a build that writes redirected paths and
                    -- registers nothing.
                    case config >>= configSharedScheduler of
                      Just shared | jobMode == Normal -> withGoal shared path
                        (daemonOwnedBuild config userPool settings trace hook jobMode requested path)
                      _ -> buildDerivationNow userPool config rootFd store settings trace hook jobMode requested path
                    pure Done
                  else do
                    writeIORef phase True
                    buildDerivation attemptedDownloads (discover inputMode) config rootFd store settings trace hook jobMode requested path }
  specs <- forM things $ \thing -> do
    let (path, wanted) = case B.break (== 33) thing of
          (drv, selected) | not (B.null selected) ->
            (drv, Set.fromList (filter (not . B.null) (C.split ',' (B.drop 1 selected))))
          _ -> (thing, Set.empty)
    if ".drv" `B.isSuffixOf` path
      then discover mode path wanted BuildJob
      else discover mode (downloadJobId thing) Set.empty DownloadJob
  let maxJobs = settingInt "build-max-jobs" 1 settings
      separateDownloads = if settingBool "build-separate-download-slots" False settings
        then Just (settingInt "build-max-download-jobs" 1 settings)
        else Nothing
      shared = config >>= configSharedScheduler
  -- HS-12: this client's build-max-jobs raises the daemon-wide shared limit, so
  -- the one shared limit is never tighter than a client's request (the C++
  -- daemon reads the connection's build-max-jobs setting).
  forM_ shared (\s -> raiseLimit s maxJobs)
  when (maxJobs == 0 && separateDownloads == Nothing &&
      not (settingBool "build-use-build-hook" True settings) && not (null things)) $
    throwIO (storeError "unable to start any build; either increase `--max-jobs' or enable distributed builds")
  runScheduledShared shared maxJobs separateDownloads (keepGoing settings) (discover inputMode) specs cancel

ensureStorePath :: ServerConfig -> Fd -> Store -> Settings -> BuildTrace -> ByteString -> IO ()
ensureStorePath config rootFd store settings trace path = do
  substituted <- trySubstitute config rootFd store settings trace path
  unless substituted $ throwIO (storeError ("path `" ++ C.unpack path ++ "' does not exist and cannot be created"))

buildThings :: Fd -> Store -> Settings -> [ByteString] -> BuildMode -> IO ()
buildThings rootFd store settings things mode =
  buildThingsWithTrace rootFd store settings (BuildTrace (\_ _ _ _ -> pure ()) (\_ -> pure ()) (\_ _ -> pure ()) (\_ -> pure ())) things mode

buildDerivation :: IORef (Set.Set ByteString) -> (ByteString -> Set.Set ByteString -> JobKind -> IO JobSpec) -> Maybe ServerConfig -> Fd -> Store -> Settings -> BuildTrace -> Maybe HookPool -> BuildMode -> Set.Set ByteString -> ByteString -> IO (Outcome [Dependency])
buildDerivation attemptedDownloads discover config rootFd store settings trace hook mode wanted drvPath = do
  appendTempRoot rootFd drvPath
  valid <- isValidPath store drvPath
  unless valid $ case config of
    Just serverConfig | mode == Normal -> do
      -- As in DerivationGoal::init, a missing derivation may itself be
      -- substitutable.  Failure to find it is reported by the caller.
      _ <- trySubstitute serverConfig rootFd store settings trace drvPath
      pure ()
    _ -> pure ()
  stillValid <- isValidPath store drvPath
  unless stillValid $ throwIO (storeError ("cannot build missing derivation `" ++ C.unpack drvPath ++ "'"))
  bytes <- B.readFile (C.unpack drvPath)
  drv <- either (throwIO . storeError) pure (parseDerivation bytes)
  mapM_ (appendTempRoot rootFd . outputPath) (Map.elems (outputs drv))
  let unknown = Set.difference wanted (Map.keysSet (outputs drv))
  unless (Set.null unknown) $
    throwIO (storeError ("derivation `" ++ C.unpack drvPath ++ "' does not have requested output `" ++ C.unpack (Set.findMin unknown) ++ "'"))
  let selectedOutputs = if Set.null wanted then outputs drv else Map.restrictKeys (outputs drv) wanted
      requestedPaths = map outputPath (Map.elems selectedOutputs)
  ready <- and <$> mapM (isValidPath store . outputPath) (Map.elems selectedOutputs)
  -- C++ haveDerivation(): AlreadyValid is terminal in normal mode. Requested
  -- input outputs can be valid even when another output of that drv is absent.
  if ready && mode == Normal
    then pure Done
    else buildDerivationMissing requestedPaths drvPath drv
  where
    buildDerivationMissing requestedPaths drvPath drv = do
      failed <- if mode == Normal && settingBool "build-cache-failures" False settings
        then or <$> mapM (hasPathFailed store . outputPath) (Map.elems (outputs drv))
        else pure False
      when failed $ do
        traceFailed trace drvPath "cached"
        throwIO (storeError ("build of `" ++ C.unpack drvPath ++ "' failed previously (cached)"))
      deferred <- if settingBool "build-separate-download-slots" False settings && hook == Nothing && mode /= Check
        then do
          attempted <- readIORef attemptedDownloads
          pure [path | path <- requestedPaths, Set.notMember path attempted]
        else pure []
      case (deferred, config) of
        (_:_, Just _) -> pure (Need [(downloadJobId path, Set.empty, DownloadJob) | path <- deferred])
        _ -> do
          substituted <- case config of
            Just serverConfig | mode /= Check && settingBool "build-use-substitutes" False settings ->
              and <$> mapM (trySubstitute serverConfig rootFd store settings trace) requestedPaths
            _ -> pure False
          if mode /= Repair && mode /= Check && substituted
            then pure Done
            else pure (Need [(input, selected, BuildJob) | (input, selected) <- Map.toList (inputDrvs drv)])

buildDerivationNow :: Maybe UserPool -> Maybe ServerConfig -> Fd -> Store -> Settings -> BuildTrace -> Maybe HookPool -> BuildMode -> Set.Set ByteString -> ByteString -> IO ()
buildDerivationNow userPool config rootFd store settings trace hook mode wanted drvPath = do
  bytes <- B.readFile (C.unpack drvPath)
  drv <- either (throwIO . storeError) pure (parseDerivation bytes)
  forM_ (Set.toList (inputSrcs drv)) $ \input -> do
    present <- isValidPath store input
    unless present $ throwIO (storeError ("input `" ++ C.unpack input ++ "' is not valid"))
  buildWithHook userPool rootFd store settings trace hook mode drvPath drv

-- | HS-12: a build run by the daemon-owned shared goal.  It owns its temporary
-- roots and its store handle (the client that started the goal may disconnect,
-- releasing its roots and closing its store), and its trace tolerates a gone
-- client.  The goal outlives any one client while another is still interested.
daemonOwnedBuild :: Maybe ServerConfig -> Maybe UserPool -> Settings -> BuildTrace -> Maybe HookPool -> BuildMode -> Set.Set ByteString -> ByteString -> IO ()
daemonOwnedBuild config userPool settings trace hook mode wanted drvPath = case config of
  Nothing -> pure ()
  Just serverConfig -> do
    pid <- getProcessID
    let rootPath = tempRootsDir serverConfig <> "/" <> C.pack (show pid <> "-goal-" <> C.unpack (storePathToName (configStore serverConfig) drvPath))
        gcPath = storeGcLockPathOf (configStore serverConfig) (configStateDirectory serverConfig)
        tolerant = tolerantTrace trace
    withTempRootFile rootPath gcPath $ \goalRootFd ->
      bracket (openStore (configStore serverConfig) (configDatabase serverConfig)) closeStore $ \goalStore ->
        buildDerivationNow userPool config goalRootFd goalStore { storeStateDirectory = configStateDirectory serverConfig } settings tolerant hook mode wanted drvPath

-- | The temporary-roots directory of a store, as the server uses it.
tempRootsDir :: ServerConfig -> ByteString
tempRootsDir config = case configStateDirectory config of
  Just state -> state <> "/temproots"
  Nothing -> "/tmp/goonix-temproots"

-- | A trace that tolerates a gone client: the daemon-owned goal may outlive the
-- client that started it, whose socket is then closed.  A write to that socket
-- fails; swallow the error so the build keeps running for the other clients.
tolerantTrace :: BuildTrace -> BuildTrace
tolerantTrace trace = BuildTrace
  { traceStarted = \drv platform log pid -> swallow (traceStarted trace drv platform log pid)
  , traceSucceeded = \drv -> swallow (traceSucceeded trace drv)
  , traceFailed = \drv reason -> swallow (traceFailed trace drv reason)
  , traceOutput = \bytes -> swallow (traceOutput trace bytes)
  }
  where
    swallow action = action `catch` (\(_ :: SomeException) -> pure ())

buildWithHook :: Maybe UserPool -> Fd -> Store -> Settings -> BuildTrace -> Maybe HookPool -> BuildMode -> ByteString -> Derivation -> IO ()
buildWithHook userPool rootFd store settings trace pool mode drvPath drv = do
  let localBuild = do
        runBuilder userPool rootFd store settings trace mode drvPath drv
        when (mode == Normal) $ replicateM_ (max 0 (settingInt "build-repeat" 0 settings)) $
          runBuilder userPool rootFd store settings trace Check drvPath drv
      withOutputLocks action =
        foldr (\path inner -> withPathLock path inner) action (map outputPath (Map.elems (outputs drv)))
      tryBuild Nothing = withOutputLocks $ do
        ready <- allOutputsValid store drv
        if ready && mode == Normal then pure () else localBuild
      tryBuild (Just currentPool)
        | mode /= Normal || willBuildLocally settings drv = withOutputLocks $ do
            ready <- allOutputsValid store drv
            if ready && mode == Normal then pure () else localBuild
        | otherwise = withOutputLocks $ do
            outcome <- bracketOnError (acquireHook settings currentPool)
              (\hook -> writeIORef (fst currentPool) Nothing >> stopHook hook) $ \hook ->
              offer currentPool hook
            case outcome of
              BuildRemotely hook -> do
                -- Acceptance transfers the hook out of the pool.  The helper
                -- exits after one accepted build; unlike decline/postpone it
                -- must never be offered to another derivation.
                writeIORef (fst currentPool) Nothing
                finally
                  (do
                    inputRoots <- Set.toList <$> derivationInputs store drvPath Set.empty drv
                    inputs <- Set.toList . Set.fromList . concat <$> mapM (referenceClosure store) (drvPath:inputRoots)
                    let outputPaths = map outputPath (Map.elems (outputs drv))
                    logPath <- buildLogPath settings store drvPath
                    mkdirParents (C.pack (takeDirectory (C.unpack logPath)))
                    traceStarted trace drvPath (platform drv) logPath (fromIntegral (hookPid hook))
                    acceptOffload hook inputs outputPaths
                    bracket (openLog settings logPath) closeLog $ \logHandle -> do
                      outputLock <- newMVar ()
                      let emit bytes = withMVar outputLock $ \_ -> writeLog logHandle bytes >> traceOutput trace bytes
                      status <- finishOffload hook emit
                      valid <- and <$> mapM (isValidPath store) outputPaths
                      case (status, valid) of
                        (HelperExited 0, True) -> traceSucceeded trace drvPath
                        _ -> offloadFailed settings store trace drvPath drv status)
                  (stopHook hook)
              BuildLocally -> do
                -- `offer` returns BuildLocally for an output that is already
                -- valid (as well as when the hook declines).  Re-check inside
                -- the output locks: another client may have registered the
                -- output since this goal decided to build, and rebuilding it
                -- would delete a path a concurrent build is using.  C++
                -- re-checks validity after acquiring the output locks and skips
                -- a valid output (DerivationGoal::tryToBuild, "someone beat us
                -- to it").
                ready <- allOutputsValid store drv
                if ready && mode == Normal then pure () else localBuild
      offer currentPool hook = do
        ready <- allOutputsValid store drv
        if ready then releaseHook currentPool hook >> pure BuildLocally else do
          -- C++ holds the output locks while offering the job to the hook.
          reply <- requestOffload hook (traceOutput trace) True (platform drv) drvPath
            (C.words (Map.findWithDefault "" "requiredSystemFeatures" (environment drv)))
          case reply of
            HookDecline -> releaseHook currentPool hook >> pure BuildLocally
            HookPostpone -> do
              -- waitForAWhile: keep the same live hook for the next offer.
              threadDelay 5000000
              offer currentPool hook
            HookAccept -> pure (BuildRemotely hook)
  tryBuild pool

data HookOutcome = BuildLocally | BuildRemotely Hook

acquireHook :: Settings -> HookPool -> IO Hook
acquireHook settings (state, program) = do
  existing <- readIORef state
  case existing of
    Just hook -> do
      writeIORef state Nothing
      pure hook
    Nothing -> startHelper settings program

releaseHook :: HookPool -> Hook -> IO ()
releaseHook (state, _) = writeIORef state . Just

willBuildLocally :: Settings -> Derivation -> Bool
willBuildLocally settings drv =
  Map.findWithDefault "" "preferLocalBuild" (environment drv) == "1" &&
    (platform drv == system || (platform drv == "i686-linux" && system == "x86_64-linux") ||
      (platform drv == "armhf-linux" && system == "aarch64-linux"))
  where system = setting "system" "x86_64-linux" settings

offloadProgram :: ServerConfig -> IO (Maybe ByteString)
offloadProgram config = do
  configured <- getEnv "GUIX"
  override <- getEnv "GOONIX_OFFLOAD_PROGRAM"
  pure $ Just $ case override of
    Just path -> path
    Nothing -> maybe (configGuixProgram config) id configured

startHelper :: Settings -> ByteString -> IO Hook
startHelper settings = \program -> startOffloadHook program (setting "system" "x86_64-linux" settings)
  (settingInt "build-max-silent-time" 3600 settings) (printBuildTrace settings) (settingInt "build-timeout" 86400 settings)

offloadFailed :: Settings -> Store -> BuildTrace -> ByteString -> Derivation -> HelperStatus -> IO a
offloadFailed settings store trace drvPath drv status = do
  let statusCode = case status of
        HelperExited code | code `elem` [100, 101] -> fromIntegral code
        _ -> 1
      reason = case status of
        HelperExited 0 -> "failed to produce all outputs"
        HelperExited code -> "failed with exit code " ++ show code
        HelperSignalled signal -> "failed due to signal " ++ show signal
        HelperAbnormal -> "died abnormally"
      failure = "offload helper for `" ++ C.unpack drvPath ++ "' " ++ reason
  case status of
    HelperExited 101 -> traceFailed trace drvPath "timeout"
    HelperExited 100 -> traceFailed trace drvPath failure
    HelperExited 0 -> traceFailed trace drvPath failure
    _ -> pure ()
  when (statusCode == 100 && settingBool "build-cache-failures" False settings && not (isFixedOutput drv)) $
    mapM_ (registerFailedPath store . outputPath) (Map.elems (outputs drv))
  throwIO (StoreError (C.pack ("build of " ++ C.unpack drvPath ++ " failed: " ++ failure)) statusCode)

derivationInputs :: Store -> ByteString -> Set.Set ByteString -> Derivation -> IO (Set.Set ByteString)
derivationInputs store drvPath seen current = do
  let direct = Set.filter (\path -> not ("builtin:" `B.isPrefixOf` path))
        (if "builtin:" `B.isPrefixOf` builder current
          then inputSrcs current
          else Set.insert (topLevelStorePath store (builder current)) (inputSrcs current))
  dependencies <- mapM (\(path, selected) -> (\drv -> (path, selected, drv)) <$> readStoreDerivation path)
    (filter (\(path, _) -> Set.notMember path seen) (Map.toList (inputDrvs current)))
  let dependencyOutputs = Set.fromList
        [ outputPath output
        | (path, selected, dependency) <- dependencies
        , output <- Map.elems (if Set.null selected then outputs dependency else Map.restrictKeys (outputs dependency) selected)
        ]
  foldM (\seen' (path, _selected, drv) -> derivationInputs store path seen' drv) (Set.insert drvPath (Set.union seen (Set.union direct dependencyOutputs))) dependencies
  where
    readStoreDerivation path = do
      bytes <- B.readFile (C.unpack path)
      either (throwIO . storeError) pure (parseDerivation bytes)

trySubstitute :: ServerConfig -> Fd -> Store -> Settings -> BuildTrace -> ByteString -> IO Bool
trySubstitute config rootFd store settings trace path = do
  valid <- isValidPath store path
  if valid then pure True else do
    infos <- substitutableInfos config settings [path]
    case infos of
      [] -> pure False
      ((_, deriver, references, _, _):_) -> do
        mapM_ (appendTempRoot rootFd) (path:references)
        present <- mapM (isValidPath store) references
        unless (and present) (throwIO (storeError ("substitute references of `" ++ C.unpack path ++ "' are not valid")))
        withPathLock path $ do
          validNow <- isValidPath store path
          if validNow then pure True else do
            deleteTree path
            traceOutput trace ("@ substituter-started " <> path <> " substitute\n")
            result <- substitutePath config settings path path
            case result of
              Left message -> do
                when ("hash-mismatch" `B.isPrefixOf` message) $
                  case C.words message of
                    (_:algorithm:expected:actual:_) ->
                      traceOutput trace ("@ hash-mismatch " <> path <> " " <> algorithm <> " " <> expected <> " " <> actual <> "\n")
                    _ -> pure ()
                traceOutput trace ("@ substituter-failed " <> path <> " " <> message <> "\n")
                if settingBool "build-fallback" False settings
                  then pure False
                  else throwIO (storeError ("fetching path `" ++ C.unpack path ++ "' failed: " ++ C.unpack message))
              Right (printedHash, size) -> do
                digest <- case C.break (== ':') printedHash of
                  ("sha256", encoded) -> either (throwIO . storeError) pure (decodeBase32 (B.drop 1 encoded))
                  _ -> throwIO (storeError "unsupported substitute hash")
                exists <- Files.fileExist path
                unless exists $ throwIO (storeError ("substitute did not produce path `" ++ C.unpack path ++ "'"))
                (actualHash, _) <- canonicaliseAndHash store path
                when (hashDigest actualHash /= digest) $ do
                  deleteTree path
                  throwIO (storeError ("corrupt output path `" ++ C.unpack path ++ "' from substitute"))
                deduplicateTree (storeDirectory store) path
                registerPath store path actualHash size references deriver
                traceOutput trace ("@ substituter-succeeded " <> path <> "\n")
                pure True

allOutputsValid :: Store -> Derivation -> IO Bool
allOutputsValid store drv = and <$> mapM (isValidPath store . outputPath) (Map.elems (outputs drv))

runBuilder :: Maybe UserPool -> Fd -> Store -> Settings -> BuildTrace -> BuildMode -> ByteString -> Derivation -> IO ()
runBuilder userPool rootFd store settings trace mode drvPath drv =
  case userPool of
    Nothing -> runBuilderWithUser Nothing rootFd store settings trace mode drvPath drv
    Just pool -> withBuildUser pool $ \user ->
      runBuilderWithUser (Just user) rootFd store settings trace mode drvPath drv

runBuilderWithUser :: Maybe BuildUser -> Fd -> Store -> Settings -> BuildTrace -> BuildMode -> ByteString -> Derivation -> IO ()
runBuilderWithUser buildUser rootFd store settings trace mode drvPath drv = do
  let isBuiltin = "builtin:" `B.isPrefixOf` builder drv
      outPaths = map outputPath (Map.elems (outputs drv))
      redirected = if mode == Check then map (redirectOutput store drvPath) outPaths else outPaths
      replacements = zip outPaths redirected
      actualDrv = if mode == Check then replaceDerivationPaths replacements drv else drv
  mapM_ (appendTempRoot rootFd) outPaths
  inputRoots <- derivationInputs store drvPath Set.empty drv
  mapM_ (appendTempRoot rootFd) (Set.toList inputRoots)
  withWritableStore (storeDirectory store) $ mapM_ deleteTree redirected
  work <- makeBuildDirectory store
  forM_ buildUser $ \user ->
    Files.setOwnerAndGroup work (fromIntegral (buildUserUid user)) (fromIntegral (buildUserGid user))
  prepareReferenceGraphs store work drv
  env <- builderEnvironment store settings work actualDrv
  logPath <- buildLogPath settings store drvPath
  mkdirParents (C.pack (takeDirectory (C.unpack logPath)))
  logHandle <- openLog settings logPath
  (readFd, writeFd) <- createPipe
  writeHandle <- fdToHandle writeFd
  readHandle <- fdToHandle readFd
  guixProgram <- maybe "guix" C.unpack <$> getEnv "GUIX"
  let command = if "builtin:" `B.isPrefixOf` builder drv
        then proc guixProgram ["perform-download", C.unpack drvPath, C.unpack (outputPath (outputs actualDrv Map.! "out"))]
        else proc (C.unpack (builder drv)) (map C.unpack (args drv))
  (childPid, wait, sandboxRoot, sandboxOutputs) <-
    try (mask $ \restore -> do
    spawned <- if settingBool "build-use-sandbox" True settings && not (isBuiltin)
      then spawnSandboxedBuilder buildUser settings store work drvPath actualDrv command env writeFd
      else do
        -- As in builtins.cc, the downloader inherits the daemon's environment.
        inherited <- if isBuiltin then getEnvironment else pure []
        let childEnvironment = if isBuiltin then inherited else env
        (_, _, _, process) <- createProcess command
          { cwd = Just (C.unpack work), env = Just childEnvironment, std_out = UseHandle writeHandle, std_err = UseHandle writeHandle, create_group = True }
        pid <- maybe 0 fromIntegral <$> getPid process
        pure (pid, waitForProcess process, Nothing, [])
    let (pid, _, _, _) = spawned
    -- The child exists before this handler is installed only while masked.
    -- Cancellation after this point cannot orphan it in the fork/wait gap.
    restore (pure spawned) `onException` killBuilder pid)
    >>= \case
      Left (exception :: IOException) -> do
        hClose writeHandle
        hClose readHandle
        let errorText = if isDoesNotExistError exception then "No such file or directory"
              else ioeGetErrorString exception
            message = "while setting up the child process: in phase exec: getting status of `"
              ++ C.unpack (builder drv) ++ "': " ++ errorText ++ "\n"
            failure = "build of `" ++ C.unpack drvPath ++ "' failed"
        writeLog logHandle (C.pack message)
        closeLog logHandle
        traceFailed trace drvPath "builder failed"
        when (mode == Normal && settingBool "build-cache-failures" False settings && not (isFixedOutput drv)) $
          mapM_ (registerFailedPath store . outputPath) (Map.elems (outputs drv))
        if keepFailed settings then pure () else removeBuildDirectory work
        throwIO (StoreError (C.pack failure) 100)
      Right spawned -> pure spawned
  traceStarted trace drvPath (platform drv) logPath childPid
  hClose writeHandle
  lastOutput <- getPOSIXTime >>= newIORef
  drained <- newEmptyMVar
  _ <- forkIO $ copyLog childPid (settingBool "multiplexed-build-output" False settings) readHandle logHandle trace lastOutput `finally` putMVar drained ()
  (status, timeoutReason) <- waitForBuilder settings childPid wait lastOutput
    `onException` killBuilder childPid
  takeMVar drained `onException` hClose readHandle
  hClose readHandle
  closeLog logHandle
  case status of
    ExitSuccess -> do
      forM_ sandboxRoot $ \root -> forM_ sandboxOutputs $ \path -> do
        let produced = root <> path
        exists <- Files.fileExist produced
        unless exists $ throwIO (storeError ("builder for `" ++ C.unpack drvPath ++ "' failed: did not produce output `" ++ C.unpack path ++ "'"))
        deleteTree path
        makeParentsWritable root path
        copyTree produced path
      forM_ sandboxRoot $ \root -> do
        Files.setFileMode root 0o755
        deleteTree root
      registration <- try $ if mode == Check
        then checkBuiltOutputs store drvPath replacements (keepFailed settings)
        else registerBuiltOutputs store drvPath drv
      case registration of
        Left (exception :: SomeException) -> do
          forM_ redirected $ \path -> deleteTree path
          let (message, status) = registrationFailure exception
          buildFailed work (Just (message, status))
        Right () -> pure ()
      removeBuildDirectory work
      traceSucceeded trace drvPath
    _ -> do
      forM_ sandboxRoot $ \root -> do
        Files.setFileMode root 0o755
        deleteTree root
      buildFailed work ((, 101) <$> timeoutReason)
  where
    -- Output registration can fail after a successful builder.  It is not a
    -- timeout, and its StoreError status must survive rather than becoming
    -- the timeout status 101 (which would also disable the failure cache).
    registrationFailure exception =
      case fromException exception of
        Just (StoreError message status) -> (C.unpack message, status)
        Nothing -> (show exception, 1)
    buildFailed work timeoutReason = do
      let (failure, status) = case timeoutReason of
            Just reason -> reason
            Nothing -> ("builder failed", 1)
          timedOut = status == 101
          reason = "failed: " ++ failure
      traceFailed trace drvPath (if timedOut then "timeout" else "builder failed")
      when (mode == Normal && not timedOut && settingBool "build-cache-failures" False settings && not (isFixedOutput drv)) $
        mapM_ (registerFailedPath store . outputPath) (Map.elems (outputs drv))
      if keepFailed settings
        then pure ()
        else removeBuildDirectory work
      throwIO (StoreError (C.pack ("build of " ++ C.unpack drvPath ++ " " ++ reason)) status)

foreign import ccall unsafe "goonix_spawn_sandbox"
  c_spawn_sandbox :: CString -> CString -> CInt -> Ptr CInt -> IO CInt

topLevelStorePath :: Store -> RawFilePath -> RawFilePath
topLevelStorePath store path =
  storeDirectory store <> "/" <> C.takeWhile (/= '/') (B.drop (B.length (storeDirectory store) + 1) path)

makeParentsWritable :: RawFilePath -> RawFilePath -> IO ()
makeParentsWritable root path = go (C.split '/' path) root
  where
    go [] _ = pure ()
    go [_] _ = pure ()
    go (component:rest) parent = do
      let directory = parent <> "/" <> component
      Files.setFileMode directory 0o755
      go rest directory

copyTree :: RawFilePath -> RawFilePath -> IO ()
copyTree source destination = do
  status <- Files.getSymbolicLinkStatus source
  if Files.isSymbolicLink status
    then do
      target <- Files.readSymbolicLink source
      Files.createSymbolicLink target destination
    else if Files.isDirectory status
      then do
        Dir.createDirectory destination 0o755
        entries <- directoryEntries source
        forM_ entries $ \entry -> copyTree (source <> "/" <> entry) (destination <> "/" <> entry)
        Files.setOwnerAndGroup destination (fileOwner status) (fileGroup status)
        Files.setFileMode destination (Files.fileMode status)
      else do
        bytes <- B.readFile (C.unpack source)
        B.writeFile (C.unpack destination) bytes
        Files.setOwnerAndGroup destination (fileOwner status) (fileGroup status)
        Files.setFileMode destination (Files.fileMode status)

spawnSandboxedBuilder :: Maybe BuildUser -> Settings -> Store -> RawFilePath -> RawFilePath -> Derivation -> CreateProcess -> [(String, String)] -> Fd -> IO (Int, IO ExitCode, Maybe RawFilePath, [RawFilePath])
spawnSandboxedBuilder buildUser settings store work drvPath drv command env (Fd logFd) = do
  helper <- do
    explicit <- getEnv "GUIX_SANDBOX"
    case explicit of
      Just path -> pure path
      Nothing -> do
        executable <- getExecutablePath
        pure (C.pack (takeDirectory executable) <> "/guix-sandbox")
  root <- makeSandboxRoot store
  mkdirParents (root <> "/tmp")
  Files.setFileMode (root <> "/tmp") 0o1777
  hostUid <- fromIntegral <$> getEffectiveUserID
  hostGid <- fromIntegral <$> getEffectiveGroupID
  let (uid, gid) = maybe (hostUid, hostGid) (\user -> (buildUserUid user, buildUserGid user)) buildUser
      (insideUid, insideGid) = maybe (30001, 30000) (\user -> (buildUserUid user, buildUserGid user)) buildUser
      hostIdentities = hostUid == 0 && maybe False (const True) buildUser
      identityFlag = if hostIdentities then sandboxFlagHostIdentities else 0
      userNamespaceFlag = if hostIdentities then 0 else sandboxFlagUserNamespace
      lockMountsFlag = if hostIdentities then 0 else sandboxFlagLockMounts
  network <- fixedOutputNetwork settings drv
  let (networkFlags, slirpProgram, slirpFilter) = case network of
        Nothing -> (0, "", [])
        Just (program, ipv6, isolate) ->
          (sandboxFlagSlirpNetwork .|. (if ipv6 then sandboxFlagIpv6Network else 0) .|.
            (if isolate then sandboxFlagIsolateHostLoopback else 0),
            C.pack program, slirpSeccompFilter nativeArchitecture)
  inputs <- derivationInputs store drvPath Set.empty drv
  let writableInputs = Set.fromList [work, storeDirectory store]
  closure <- Set.unions . map Set.fromList <$> mapM (referenceClosure store) (Set.toList inputs)
  let sandboxWork = "/tmp/guix-build-" <> storePathToName (storeDirectory store) drvPath <> "-0"
      program = case cmdspec command of
        RawCommand executable _ -> C.pack executable
        ShellCommand _ -> throwIO (storeError "shell builders are not supported") `seq` B.empty
      arguments = case cmdspec command of
        RawCommand executable args -> C.pack executable : map C.pack args
        ShellCommand _ -> []
      environment = map (\(name, value) -> (C.pack name, C.pack value)) env
      replaceWork path = if work `B.isPrefixOf` path then sandboxWork <> B.drop (B.length work) path else path
      environment' = map (\(name, value) -> (name, replaceWork value)) (Map.toList (Map.fromList environment))
      mountInputs = [BindMount path path (not (Set.member path writableInputs)) | path <- Set.toList closure]
      mountOutputs = []
      mountWork = [BindMount work sandboxWork False]
      configured = filter (not . B.null) (C.words (setting "build-chroot-dirs" "" settings <> " " <> setting "build-extra-chroot-dirs" "" settings))
      extraMounts = map (\path -> let (source, target) = B.break (== 61) path
                                   in BindMount source (if B.null target then source else B.drop 1 target) False) configured
      devices = [BindMount path path False | path <- ["/dev/null", "/dev/full", "/dev/zero", "/dev/random", "/dev/urandom", "/dev/tty"]]
      plan = SandboxPlan
        { planFlags = identityFlag .|. userNamespaceFlag .|. sandboxFlagMountNamespace .|.
          sandboxFlagNetworkNamespace .|. sandboxFlagPidNamespace .|. sandboxFlagIpcNamespace .|.
          sandboxFlagUtsNamespace .|. sandboxFlagChroot .|. sandboxFlagProc .|. sandboxFlagDevpts .|.
          lockMountsFlag .|. sandboxFlagSetSid .|. sandboxFlagCloseFds .|.
          sandboxFlagChdir .|. sandboxFlagStdinFile .|. sandboxFlagClearGroups .|.
          sandboxFlagNoNewPrivs .|. maybe 0 (const sandboxFlagSetIds) buildUser .|. networkFlags
        , planProgram = program, planArguments = arguments, planEnvironment = environment'
        , planWorkingDirectory = sandboxWork, planStdinFile = "/dev/null"
        , planUid = insideUid, planGid = insideGid, planStdinFd = maxBound, planLogFd = maxBound
        , planGroups = maybe [] buildUserGroups buildUser, planCloseFds = []
        , planUidMapInside = insideUid, planUidMapOutside = uid
        , planGidMapInside = insideGid, planGidMapOutside = gid
        , planRoot = root, planStoreDirectory = storeDirectory store, planHostname = "localhost", planDomainname = "(none)"
        , planMounts = mountInputs ++ mountOutputs ++ mountWork ++ extraMounts ++ devices
        , planSeccomp = []
        , planSlirpProgram = slirpProgram, planSlirpSeccomp = slirpFilter
        }
      planPath = root <> ".plan"
  mkdirParents (root <> "/etc")
  B.writeFile (C.unpack (root <> "/etc/passwd"))
    (C.pack ("nixbld:x:" ++ show insideUid ++ ":" ++ show insideGid ++ ":Nix build user:/:/noshell\n") <> "nobody:x:65534:65534:Nobody:/:/noshell\n")
  B.writeFile (C.unpack (root <> "/etc/group"))
    (C.pack ("nixbld:!:" ++ show insideGid ++ ":\n"))
  B.writeFile (C.unpack (root <> "/etc/hosts")) "127.0.0.1 localhost\n::1 localhost\n"
  when (isFixedOutput drv) $ do
    forM_ ["/etc/services", "/etc/nsswitch.conf"] (copyEtcFile root)
    case network of
      Nothing -> forM_ ["/etc/hosts", "/etc/resolv.conf"] (copyEtcFile root)
      Just (_, _, isolate) -> do
        B.writeFile (C.unpack (root <> "/etc/resolv.conf")) "nameserver 10.0.2.3\n"
        if isolate
          then copyEtcFile root "/etc/hosts"
          else do
            hosts <- B.readFile "/etc/hosts" `catch` \(_ :: SomeException) -> pure "127.0.0.1 localhost\n::1 localhost\n"
            B.writeFile (C.unpack (root <> "/etc/hosts"))
              (replaceBytes "::1" "fd00::2" (replaceBytes "127.0.0.1" "10.0.2.2" hosts))
  B.writeFile (C.unpack planPath) (encodeSandboxPlan plan)
  withCString (C.unpack helper) $ \program' -> withCString (C.unpack planPath) $ \path' -> alloca $ \pidPointer -> do
    result <- c_spawn_sandbox program' path' logFd pidPointer
    if result < 0 then throwIO (storeError "cannot spawn sandbox helper") else do
      pid <- fromIntegral <$> peek pidPointer
      pure (pid, waitForSandbox pid, Just root, map outputPath (Map.elems (outputs drv)))

copyEtcFile :: RawFilePath -> RawFilePath -> IO ()
copyEtcFile root path =
  (B.readFile (C.unpack path) >>= \contents -> B.writeFile (C.unpack (root <> path)) contents)
    `catch` \(_ :: SomeException) -> pure ()

fixedOutputNetwork :: Settings -> Derivation -> IO (Maybe (FilePath, Bool, Bool))
fixedOutputNetwork settings drv
  | not (isFixedOutput drv) = pure Nothing
  | otherwise = do
      configured <- lookupEnv "GUIX_SLIRP4NETNS"
      program <- case configured of
        Just path | not (null path) -> pure (Just path)
        _ -> findExecutable "slirp4netns"
      tun <- Files.fileExist "/dev/net/tun"
      case (program, tun) of
        (Just path, True) -> do
          ipv6 <- hasGlobalIpv6
          pure (Just (path, ipv6, settingBool "build-isolate-host-loopback" False settings))
        _ -> do
          hPutStrLn stderr "guix-daemon: fixed-output network access disabled (slirp4netns or /dev/net/tun unavailable)"
          pure Nothing
  where
    hasGlobalIpv6 = do
      contents <- B.readFile "/proc/net/if_inet6" `catch` \(_ :: SomeException) -> pure ""
      pure (any (\line -> case C.words line of
        (_:_:_:scope:_) -> scope == "00" || scope == "40"
        _ -> False) (C.lines contents))

killBuilder :: Int -> IO ()
killBuilder pid = signalProcessGroup sigKILL (fromIntegral pid) `catch` \exception ->
  if isDoesNotExistError exception then pure () else throwIO exception

waitForBuilder :: Settings -> Int -> IO ExitCode -> IORef POSIXTime -> IO (ExitCode, Maybe String)
waitForBuilder settings pid wait lastOutput = do
  started <- getPOSIXTime
  status <- newEmptyMVar
  reason <- newIORef Nothing
  _ <- forkIO (try wait >>= putMVar status)
  let total = settingInt "build-timeout" 0 settings
      silent = settingInt "build-max-silent-time" 0 settings
      stop why = do
        atomicWriteIORef reason (Just why)
        signalProcessGroup sigKILL (fromIntegral pid) `catch` \exception ->
          if isDoesNotExistError exception then pure () else throwIO exception
      watch = do
        threadDelay 100000
        now <- getPOSIXTime
        latest <- readIORef lastOutput
        if total > 0 && now - started >= fromIntegral total
          then stop "timeout"
          else if silent > 0 && now - latest >= fromIntegral silent
            then stop "silence timeout"
            else watch
  timer <- if total > 0 || silent > 0 then Just <$> forkIO watch else pure Nothing
  result <- takeMVar status
  mapM_ killThread timer
  why <- readIORef reason
  either (\(exception :: SomeException) -> throwIO exception)
    (\code -> pure (if why /= Nothing then ExitFailure 1 else code, why)) result

waitForSandbox :: Int -> IO ExitCode
waitForSandbox pid = do
  status <- getProcessStatus True False (fromIntegral pid)
  case status of
    Just (Exited code) -> pure code
    Just (Terminated _ _) -> pure (ExitFailure 1)
    Just (Stopped _) -> waitForSandbox pid
    Nothing -> throwIO (storeError "cannot wait for sandbox helper")

makeSandboxRoot :: Store -> IO RawFilePath
makeSandboxRoot store = do
  let parent = maybe "/tmp" (<> "/build") (storeStateDirectory store)
  mkdirParents parent
  pid <- getProcessID
  stamp <- getPOSIXTime
  serial <- atomicModifyIORef' buildDirectoryCounter (\n -> (n + 1, n))
  let path = parent <> "/goonix-sandbox-" <> C.pack (show pid) <> "-" <> C.pack (show (floor stamp :: Integer)) <> "-" <> C.pack (show serial)
  -- This unique name has never belonged to another builder.  Do not delete a
  -- directory before recreating it: another thread must never lose its root.
  Dir.createDirectory path 0o755
  pure path

redirectOutput :: Store -> ByteString -> RawFilePath -> RawFilePath
redirectOutput store drvPath path =
  let prefix = storeDirectory store <> "/"
      name = B.drop (B.length prefix + 32) path
      digest = encodeBase32 (sha256 ("rewrite:" <> drvPath <> ":" <> path))
  in prefix <> B.take 32 digest <> name

replaceDerivationPaths :: [(ByteString, ByteString)] -> Derivation -> Derivation
replaceDerivationPaths replacements drv = drv
  { outputs = Map.map (\output -> output { outputPath = replace (outputPath output) }) (outputs drv)
  , args = map replace (args drv)
  , environment = Map.map replace (environment drv)
  }
  where
    replace bytes = foldl (\current (old, new) -> replaceBytes old new current) bytes replacements

replaceBytes :: ByteString -> ByteString -> ByteString -> ByteString
replaceBytes old new bytes = B.intercalate new (splitBytes old bytes)

splitBytes :: ByteString -> ByteString -> [ByteString]
splitBytes separator input = case B.breakSubstring separator input of
  (before, after) | B.null after -> [before]
                  | otherwise -> before : splitBytes separator (B.drop (B.length separator) after)

checkBuiltOutputs :: Store -> ByteString -> [(ByteString, ByteString)] -> Bool -> IO ()
checkBuiltOutputs store drvPath replacements retain = forM_ replacements $ \(original, temporary) -> do
  exists <- Files.fileExist temporary
  unless exists $ throwIO (storeError ("builder for `" ++ C.unpack drvPath ++ "' did not produce output `" ++ C.unpack original ++ "'"))
  -- The check build ran with the output redirected to `temporary`, so a builder
  -- that embeds $out (e.g. the bootstrap Guile wrapper) wrote `temporary` into
  -- its output.  Rewrite those paths back to `original` before hashing, as the
  -- C++ daemon does with rewritesFromTmp; otherwise the determinism check would
  -- spuriously report a difference.
  rewriteNarPaths temporary [(temporary, original)]
  _ <- canonicaliseAndHash store temporary
  valid <- isValidPath store original
  if not valid
    then deleteTree temporary
    else do
      expected <- queryPathHash store original
      actual <- hashNar temporary
      if expected == hashDigest actual
        then deleteTree temporary
        else do
          when retain $ do
            deleteTree (original <> "-check")
            Files.rename temporary (original <> "-check")
          unless retain $ deleteTree temporary
          throwIO (storeError ("derivation `" ++ C.unpack drvPath ++ "' may not be deterministic: output `" ++ C.unpack original ++ "' differs"))

buildLogPath :: Settings -> Store -> ByteString -> IO RawFilePath
buildLogPath settings store drvPath = do
  configured <- getEnv "GUIX_LOG_DIRECTORY"
  let base = case configured of
        Just path -> path
        Nothing -> maybe "/tmp" (<> "/log/guix") (storeStateDirectory store)
      basename = B.drop (B.length (storeDirectory store) + 1) drvPath
      suffix = case setting "build-log-compression" "gzip" settings of
        "none" -> ""
        "bzip2" -> ".bz2"
        _ -> ".gz"
  pure (base <> "/drvs/" <> B.take 2 basename <> "/" <> B.drop 2 basename <> suffix)

data LogWriter = LogWriter CInt (Ptr ())

foreign import ccall unsafe "goonix_open_log"
  c_open_log :: CString -> CInt -> IO (Ptr ())
foreign import ccall safe "goonix_write_log"
  c_write_log :: Ptr () -> CInt -> Ptr a -> CSize -> IO CInt
foreign import ccall safe "goonix_close_log"
  c_close_log :: Ptr () -> CInt -> IO CInt

openLog :: Settings -> RawFilePath -> IO LogWriter
openLog settings path = do
  let kind = logKind settings
  writer <- B.useAsCString path (\path' -> c_open_log path' kind)
  if writer == nullPtr
    then throwIO (storeError ("cannot open build log `" ++ C.unpack path ++ "'"))
    else pure (LogWriter kind writer)

logKind :: Settings -> CInt
logKind settings = case setting "build-log-compression" "gzip" settings of
  "none" -> 0
  "bzip2" -> 2
  _ -> 1

writeLog :: LogWriter -> ByteString -> IO ()
writeLog (LogWriter kind writer) bytes = do
  result <- B.useAsCStringLen bytes $ \(pointer, length') ->
    c_write_log writer kind (castPtr pointer) (fromIntegral length')
  when (result < 0) (throwIO (storeError "cannot write build log"))

closeLog :: LogWriter -> IO ()
closeLog (LogWriter kind writer) = do
  result <- c_close_log writer kind
  when (result < 0) (throwIO (storeError "cannot close build log"))

copyLog :: Int -> Bool -> Handle -> LogWriter -> BuildTrace -> IORef POSIXTime -> IO ()
copyLog pid multiplexed input output trace lastOutput = do
  bytes <- B.hGetSome input 32768
  unless (B.null bytes) $ do
    getPOSIXTime >>= writeIORef lastOutput
    writeLog output bytes
    let prefix = if multiplexed
          then "@ build-log " <> C.pack (show pid) <> " " <> C.pack (show (B.length bytes)) <> "\n"
          else B.empty
    traceOutput trace (prefix <> bytes)
    copyLog pid multiplexed input output trace lastOutput

builderEnvironment :: Store -> Settings -> RawFilePath -> Derivation -> IO [(String, String)]
builderEnvironment store settings work drv = do
  let base = [("PATH", "/path-not-set"), ("HOME", "/homeless-shelter"),
              ("NIX_STORE", C.unpack (storeDirectory store)),
              ("NIX_BUILD_CORES", show (settingInt "build-cores" 0 settings))]
      custom = map (\(key, value) -> (C.unpack key, C.unpack value)) (Map.toList (environment drv))
      buildEnv = [("NIX_BUILD_TOP", C.unpack work), ("TMPDIR", C.unpack work),
                  ("TEMP", C.unpack work), ("TMP", C.unpack work),
                  ("TEMPDIR", C.unpack work), ("PWD", C.unpack work)]
  leaked <- if isFixedOutput drv
    then mapM (\name -> (C.unpack name,) . maybe "" C.unpack <$> getEnv name)
         (C.words (Map.findWithDefault "" "impureEnvVars" (environment drv)))
    else pure []
  pure (Map.toList (Map.fromList (base ++ custom ++ leaked ++ buildEnv)))

registerBuiltOutputs :: Store -> ByteString -> Derivation -> IO ()
registerBuiltOutputs store drvPath drv = forM_ (Map.elems (outputs drv)) $ \output -> do
  let path = outputPath output
  exists <- Files.fileExist path
  unless exists $ throwIO (storeError ("builder for `" ++ C.unpack drvPath ++ "' failed: did not produce output `" ++ C.unpack path ++ "'"))
  _ <- canonicaliseAndHash store path
  when (not (B.null (outputHash output))) $ verifyFixedOutput output path
  deduplicateTree (storeDirectory store) path
  (refs, hash) <- scanOutputReferences store path
  enforceReferencePolicy store drv path refs
  size <- fromIntegral . B.length <$> dumpNar path
  -- C++ keeps self-references: scanForReferences searches the output's own
  -- path among the candidates (build.cc allPaths inserts drv.outputs) and
  -- registerValidPaths adds every reference, including the path itself
  -- (local-store.cc, no self-filter).  A self-referencing output (e.g. a
  -- `self -> $out` symlink) must report itself in queryReferences, as the
  -- grafts indirect-dependency test requires.
  registerPath store path hash size refs drvPath
  where
    scanOutputReferences store path = do
      valid <- queryAllValidPaths store
      (found, hash) <- scanReferences path (path : valid)
      pure (Set.toList found, hash)

verifyFixedOutput :: DerivationOutput -> RawFilePath -> IO ()
verifyFixedOutput output path = do
  algorithm <- either (throwIO . storeError) pure (algorithmFromName (if "r:" `B.isPrefixOf` outputHashAlgo output then B.drop 2 (outputHashAlgo output) else outputHashAlgo output))
  expected <- case decodeBase16 (outputHash output) of
    Right digest | B.length digest == digestLength algorithm -> pure digest
    _ -> throwIO (storeError ("invalid " ++ C.unpack (C.map toUpperAscii (algorithmName algorithm)) ++ " hash"))
  hash <- if "r:" `B.isPrefixOf` outputHashAlgo output
    then hashNar path
    else hashFile algorithm path
  when (hashDigest hash /= expected) $
    throwIO (storeError ("output `" ++ C.unpack path ++ "' has the wrong hash"))
  where
    toUpperAscii character
      | character >= 'a' && character <= 'z' = toEnum (fromEnum character - 32)
      | otherwise = character

prepareReferenceGraphs :: Store -> RawFilePath -> Derivation -> IO ()
prepareReferenceGraphs store work drv =
  case Map.lookup "exportReferencesGraph" (environment drv) of
    Nothing -> pure ()
    Just fields -> go (C.words fields)
      where
        go [] = pure ()
        go (name:path:rest) = do
          let root = topLevelStorePath store path
          initial <- referenceClosure store root
          withOutputs <- foldM includeDerivationOutputs initial initial
          entries <- forM withOutputs $ \item -> do
            info <- queryPathInfo store item
            pure (item <> "\n\n" <> C.pack (show (length (infoReferences info))) <> "\n"
                  <> B.intercalate "\n" (infoReferences info)
                  <> if null (infoReferences info) then "" else "\n")
          B.writeFile (C.unpack (work <> "/" <> name)) (B.concat entries)
          go rest
        go _ = throwIO (storeError "odd number of tokens in exportReferencesGraph")
        includeDerivationOutputs result item
          | not (".drv" `B.isSuffixOf` item) = pure result
          | otherwise = do
              bytes <- B.readFile (C.unpack item)
              parsed <- either (throwIO . storeError) pure (parseDerivation bytes)
              expanded <- mapM (referenceClosure store . outputPath) (Map.elems (outputs parsed))
              pure (Set.toAscList (Set.fromList (result ++ concat expanded)))

referenceClosure :: Store -> RawFilePath -> IO [RawFilePath]
referenceClosure store root = go Set.empty [root]
  where
    go seen [] = pure (Set.toAscList seen)
    go seen (path:rest)
      | Set.member path seen = go seen rest
      | otherwise = do
          references <- queryReferences store path
          go (Set.insert path seen) (rest ++ references)

enforceReferencePolicy :: Store -> Derivation -> RawFilePath -> [RawFilePath] -> IO ()
enforceReferencePolicy store drv path references = do
  forM_ ["allowedReferences", "allowedRequisites", "disallowedReferences", "disallowedRequisites"] $ \attribute ->
    forM_ (Map.lookup attribute (environment drv)) $ \specification -> do
      let allowed = attribute `elem` ["allowedReferences", "allowedRequisites"]
          recursive = attribute `elem` ["allowedRequisites", "disallowedRequisites"]
      specified <- foldM expand Set.empty (C.words specification)
      used <- if recursive
        then Set.fromList . concat <$> mapM (referenceClosure store) references
        else pure (Set.fromList references)
      forM_ (Set.toList used) $ \reference ->
        when (Set.member reference specified /= allowed) $
          throwIO (storeError ("output (`" ++ C.unpack path ++ "') is not allowed to refer to path `" ++ C.unpack reference ++ "'"))
  where
    expand specified token
      | token `elem` Map.keys (outputs drv) = pure (Set.insert (outputPath (outputs drv Map.! token)) specified)
      | otherwise = do
          valid <- isValidPath store token
          if valid then pure (Set.insert token specified)
            else throwIO (storeError "invalid reference specifier")


makeBuildDirectory :: Store -> IO RawFilePath
makeBuildDirectory store = do
  let parent = maybe "/tmp" (<> "/build") (storeStateDirectory store)
  mkdirParents parent
  pid <- getProcessID
  stamp <- getPOSIXTime
  serial <- atomicModifyIORef' buildDirectoryCounter (\n -> (n + 1, n))
  let path = parent <> "/goonix-build-" <> C.pack (show pid) <> "-" <> C.pack (show (floor stamp :: Integer)) <> "-" <> C.pack (show serial)
  deleteTree path
  Dir.createDirectory path 0o700
  pure path

{-# NOINLINE buildDirectoryCounter #-}
buildDirectoryCounter :: IORef Word
buildDirectoryCounter = unsafePerformIO (newIORef 0)

removeBuildDirectory :: RawFilePath -> IO ()
removeBuildDirectory path = deleteTree path
