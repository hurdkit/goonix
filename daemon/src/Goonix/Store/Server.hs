{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.Server
  ( serve
  , serveSocket
  , serveListener
  , openListener
  , activationSockets
  , Lifecycle
  , newLifecycle
  , requestStop
  , openConnections
  , handleConnection
  , ServerConfig (..)
  , defaultConfig
  , readExactly
  , writeFrame
  ) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (IOException, SomeException, bracket, catch, finally, fromException, throwIO, try)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Set as Set
import Data.Word (Word32, Word64)
import Goonix.Store.GuixProgram (absPath)
import Goonix.Store.Database (Value (Bytes))
import Goonix.Store.Base32 (encodeBase16)
import Goonix.Store.Config (ServerConfig (..), defaultConfig)
import Goonix.Store.ReadOnly
import Goonix.Store.Settings
import Goonix.Store.Socket
import Goonix.Store.Substitute (substitutablePaths, substitutableInfos, substitutePath)
import Goonix.Store.Archive (exportPathTo, importPathsFrom)
import Goonix.Build.Engine (BuildMode (..), BuildTrace (..), buildThings, buildThingsWithConfig, buildThingsWithCancel, ensureStorePath)
import Goonix.Build.Users (loadUserPool)
import Goonix.Build.Shared (goalWorkers, newShared)
import Goonix.Store.Hash (algorithmFromName, hashDigest, Hash (..), HashAlgorithm (..))
import Goonix.Store.Base32 (decodeBase32)
import Goonix.Store.Wire
import Goonix.Store.Writing
import qualified Goonix.Store.Collector as Collector
import Goonix.Store.Path (validateStoreName)
import Goonix.Store.Ca (assertNotReserved)
import Goonix.Store.CaStore (initCaRecords, realisedOutputPath, queryGoonixBuildGraphWithLog, goonixRecordFields)
import Goonix.Store.Derivation (parseDerivation)
import Goonix.Store.Records (queryRecords)
import System.Posix.Env.ByteString (getEnv)
import Goonix.Store.Files (withTempRootFile, withCollectorGCLock, withOtherTemporaryRoots, appendTempRoot, deleteTree, mkdirParents, directoryEntries, catchMissing, deduplicateTree)
import System.Posix.IO (closeFd)
import qualified System.Posix.Files.ByteString as Files
import System.Posix.User (getUserEntryForID, userName, getGroupEntryForName, groupID)
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd (..))
import System.Posix.User (getRealUserID)
import System.IO (hPutStrLn, stderr)

-- | What the accept loops and the connections of one daemon process share so
-- that the daemon can stop in an orderly way.
--
-- The C++ daemon gives each client a process of its own, in a session of its
-- own.  A SIGTERM for its listening process ends that process alone: the
-- clients that are connected keep their session processes and are served to
-- the end.  Here every client is a thread of the process that listens, so the
-- process is asked to stop instead: it accepts nobody else, serves the clients
-- it has until each has disconnected, and only then ends.
data Lifecycle = Lifecycle
  { lifecycleStopping :: !(TVar Bool)
  , lifecycleConnections :: !(TVar Int)
  }

newLifecycle :: IO Lifecycle
newLifecycle = Lifecycle <$> newTVarIO False <*> newTVarIO 0

-- | Ask the daemon to stop.  Returns whether this call was the first to ask.
requestStop :: Lifecycle -> IO Bool
requestStop lifecycle = atomically $ do
  stopping <- readTVar (lifecycleStopping lifecycle)
  writeTVar (lifecycleStopping lifecycle) True
  pure (not stopping)

-- | The number of clients connected now.
openConnections :: Lifecycle -> IO Int
openConnections lifecycle = readTVarIO (lifecycleConnections lifecycle)

serve :: ServerConfig -> Lifecycle -> IO ()
serve config lifecycle =
  -- C++ listening_sockets with no options uses settings.nixDaemonSocketFile,
  -- derived from nixStateDir (guix-daemon.cc:396, globals.cc:68).  The
  -- client's GUIX_DAEMON_SOCKET must not redirect this daemon elsewhere.
  serveSocket config lifecycle (configStateDirectory config <> "/daemon-socket/socket")

serveSocket :: ServerConfig -> Lifecycle -> ByteString -> IO ()
serveSocket config lifecycle path = do
  listener <- openListener path
  serveListener config lifecycle listener

-- | Serve the clients of one listening socket.  Returns once the daemon has
-- been asked to stop and has nothing left to do: the socket is closed, every
-- client has disconnected, and no build that a departed client left behind is
-- still being cleaned up.
serveListener :: ServerConfig -> Lifecycle -> Socket -> IO ()
serveListener config lifecycle listener = do
  initialiseState config
  users <- loadUserPool (configStateDirectory config) (setting "build-users-group" "" (configDefaultSettings config))
  -- HS-12: one shared scheduler per daemon process — one job limit and one goal
  -- per derivation across all clients.  The daemon-wide build-max-jobs comes
  -- from the default settings; a client's own --max-jobs still bounds its
  -- request, but the shared limit bounds the whole process.
  shared <- newShared (settingInt "build-max-jobs" 1 (configDefaultSettings config))
  let sharedConfig = config { configBuildUsers = users, configSharedScheduler = Just shared }
  counter <- newMVar (0 :: Integer)
  let connections = lifecycleConnections lifecycle
      stopping = readTVar (lifecycleStopping lifecycle) >>= check
      accept = do
        next <- acceptSocketUnless stopping listener
        case next of
          Nothing -> pure ()
          Just client -> do
            -- Counted here, not in the client's thread: once this loop has
            -- returned, no client is still on its way into the count.
            atomically (modifyTVar' connections (+ 1))
            _ <- forkFinally (handleClient sharedConfig counter client)
              (const (closeSocket client `finally` atomically (modifyTVar' connections (subtract 1))))
            accept
  accept
  -- Later clients are refused, as they are once the C++ listening process is
  -- gone.  The socket file stays, as it does there.
  closeSocket listener
  atomically $ do
    clients <- readTVar connections
    workers <- goalWorkers shared
    check (clients == 0 && workers == 0)

initialiseState :: ServerConfig -> IO ()
initialiseState config = do
  mkdirParents (configStore config)
  -- C++ LocalStore ctor (local-store.cc:86-107): for a multi-user install
  -- (root daemon + build-users-group), the store is owned root:buildUsersGroup
  -- with mode 01775 so build users can create outputs (a builtin runs outside
  -- the chroot and writes the store directly).  Without this a root daemon's
  -- builtin build fails "Permission denied" writing /gnu/store/<output>.
  uid <- getRealUserID
  let buildGroup = setting "build-users-group" "" (configDefaultSettings config)
  when (uid == 0 && not (B.null buildGroup)) $ do
    groupEntry <- getGroupEntryForName (C.unpack buildGroup)
    Files.setOwnerAndGroup (configStore config) 0 (fromIntegral (groupID groupEntry))
    Files.setFileMode (configStore config) 0o1775
  let state = configStateDirectory config
  user <- getUserEntryForID uid
  mkdirParents (state <> "/gcroots/auto")
  mkdirParents (state <> "/profiles/per-user/" <> C.pack (userName user))
  Files.setFileMode (state <> "/profiles/per-user") 0o755
  Files.setFileMode (state <> "/profiles/per-user/" <> C.pack (userName user)) 0o755

activationSockets :: IO [Socket]
activationSockets = do
  listenPid <- getEnv "LISTEN_PID"
  listenFds <- getEnv "LISTEN_FDS"
  pid <- getProcessID
  case (listenPid, listenFds >>= readMaybeInt . C.unpack) of
    (Just value, Just count) | value == C.pack (show pid) && count > 0 -> do
      let sockets = map (fromFd . fromIntegral) [3 .. 2 + count]
      pure sockets
    _ -> pure []

readMaybeInt :: String -> Maybe Int
readMaybeInt value = case reads value of
  [(number, "")] -> Just number
  _ -> Nothing

openListener :: ByteString -> IO Socket
openListener path
  | not (B.isPrefixOf "/" path) = case breakLastColon path of
      Just (host, port) -> listenTcp (C.unpack host) (C.unpack port)
      Nothing -> listenTcp (C.unpack path) "44146"
  | otherwise = listenUnix path

breakLastColon :: ByteString -> Maybe (ByteString, ByteString)
breakLastColon path = case B.break (== 58) (B.reverse path) of
  (reversedPort, rest) | not (B.null rest) -> Just (B.reverse (B.drop 1 rest), B.reverse reversedPort)
  _ -> Nothing

handleClient :: ServerConfig -> MVar Integer -> Socket -> IO ()
handleClient config counter client = do
  isTcpClient <- isTcp client
  credential <- peerUid client
  uid <- getRealUserID
  let isTrusted = not isTcpClient && maybe False (\peer -> peer == 0 || fromIntegral peer == uid) credential
      settings = (configDefaultSettings config) { trusted = isTrusted, remote = isTcpClient }
  settingsRef <- newIORef settings
  pid <- getProcessID
  credentialId <- pure (maybe 0 id credential)
  rootName <- modifyMVar counter $ \value -> do
    let next = value + 1
    pure (next, C.pack (show pid <> "-" <> show next))
  catch
    (withTempRootFile (temporaryRootsPath config <> "/" <> rootName) (storeGcLockPath config) $ \rootFd ->
      bracket (openStore (configStore config) (configDatabase config) (configStateDirectory config)) closeStore $ \store -> do
        -- goonix: the records tables are created if absent (HS-11).
        initCaRecords store
        catch (handleConnection config store client settingsRef rootFd (temporaryRootsPath config <> "/" <> rootName)) report)
    report
  where
    report exception = hPutStrLn stderr ("guix-daemon: " ++ show (exception :: SomeException))

reportOperation :: String -> SomeException -> IO ()
reportOperation where' exception = hPutStrLn stderr ("guix-daemon operation " ++ where' ++ ": " ++ show exception)

temporaryRootsPath :: ServerConfig -> ByteString
temporaryRootsPath config = configStateDirectory config <> "/temproots"

storeGcLockPath :: ServerConfig -> ByteString
storeGcLockPath config = configStateDirectory config <> "/gc.lock"

handleConnection :: ServerConfig -> Store -> Socket -> IORef Settings -> Fd -> ByteString -> IO ()
handleConnection config store client settingsRef rootFd rootPath = do
  magic <- readIntSocket client
  unless (magic == workerMagic1) (throwIO (userError "protocol mismatch"))
  writeSocket client (encodeInt workerMagic2 <> encodeInt protocolVersion)
  clientVersion <- readIntSocket client
  let minor = clientVersion .&. 0xff
  when (minor >= 14) $ do
    affinity <- readIntSocket client
    when (affinity /= 0) (void (readIntSocket client))
  when (minor >= 11) (void (readIntSocket client))
  startup <- try (writeFrame client stderrLast)
  case startup of
    Left exception -> throwIO (exception :: IOException)
    Right () -> loop clientVersion
  where
    loop clientVersion = do
      next <- try (readIntSocket client)
      case next of
        Left (_ :: IOError) -> pure ()
        Right operation -> do
          result <- try (dispatch config store client settingsRef rootFd rootPath clientVersion operation)
          case result of
            Left exception -> do
              reportOperation (show operation) exception
              case fromException exception of
                Just Collector.GCLimitReached -> throwIO exception
                Nothing -> pure ()
              case fromException exception of
                Just (StoreError message status) -> writeSocket client (encodeInt stderrError <> encodeString message <> if clientVersion .&. 0xff >= 8 then encodeInt status else B.empty)
                Nothing -> writeSocket client (encodeInt stderrError <> encodeString (C.pack (show (exception :: SomeException))) <> encodeInt 1)
              loop clientVersion
            Right () -> loop clientVersion

dispatch :: ServerConfig -> Store -> Socket -> IORef Settings -> Fd -> ByteString -> Word32 -> Word32 -> IO ()
dispatch config store client settingsRef rootFd rootPath clientVersion operation = case operation of
  19 -> do
    settings <- readIORef settingsRef
    fields <- readSetOptions client clientVersion
    case applySetOptions (clientVersion .&. 0xff) fields settings of
      Left message -> throwIO (StoreError (C.pack message) 1)
      Right updated -> writeIORef settingsRef updated
    writeFrame client stderrLast
  7 -> do
    name <- readStringSocket client
    fixed <- readIntSocket client
    recursiveField <- readIntSocket client
    algorithmField <- readStringSocket client
    -- Compatibility hack (nix-daemon.cc wopAddToStore): when the obsolete
    -- `fixed' field is not 1, C++ forces BOTH sha256 AND recursive = true.
    -- Overriding only the algorithm leaves recursive false and changes the
    -- resulting path.
    let recursive = fixed /= 1 || recursiveField == 1
        algorithmName' = if fixed /= 1 then "sha256" else algorithmField
    algorithm <- either (throwIO . storeError) pure (algorithmFromName algorithmName')
    either (throwIO . storeError) pure (validateStoreName name)
    dump <- readNarSocket client
    path <- addNarToStore rootFd store name recursive algorithm dump
    writeFrame client stderrLast
    writeSocket client (encodeString path)
  9 -> do
    things <- readStringsSocket client
    mode <- if clientVersion .&. 0xff >= 15 then readIntSocket client else pure 0
    settings <- readIORef settingsRef
    when (mode == 1 && not (trusted settings)) (throwIO (storeError "repairing is a privileged operation"))
    buildThingsWithCancel config rootFd store settings (buildTrace settings client) things (if mode == 1 then Repair else if mode == 2 then Check else Normal) (waitForDisconnect client)
    writeFrame client stderrLast
    writeSocket client (encodeInt 1)
  10 -> do
    path <- readStorePath store client
    settings <- readIORef settingsRef
    ensureStorePath config rootFd store settings (buildTrace settings client) path
    writeFrame client stderrLast
    writeSocket client (encodeInt 1)
  8 -> do
    name <- readStringSocket client
    contents <- readStringSocket client
    references <- readStorePathsSocket client
    path <- addTextToStore rootFd store name contents references
    writeFrame client stderrLast
    writeSocket client (encodeString path)
  11 -> do
    path <- readStorePath store client
    appendTempRoot rootFd path
    writeFrame client stderrLast
    writeSocket client (encodeInt 1)
  12 -> do
    -- C++ wopAddIndirectRoot: `Path path = absPath(readString(from))'.  The
    -- auto root's name is SHA1 of THIS string, so an uncanonicalised value
    -- registers a second root under a different name -- and that root does not
    -- protect the item, because findRoots resolves the link the client made.
    path <- readStringSocket client >>= absPath
    addIndirectRoot store path
    writeFrame client stderrLast
    writeSocket client (encodeInt 1)
  13 -> do
    writeFrame client stderrLast
    writeSocket client (encodeInt 1)
  16 -> do
    path <- readStorePath store client
    sign <- readIntSocket client
    -- Stream the export to the socket in bounded STDERR_WRITE frames (C++
    -- TunnelSink), never materialising the whole NAR: a large output must not
    -- pin output-size bytes in the daemon heap and OOM mid-export.
    exportPathTo store path (sign == 1) (writeSocket client)
    writeFrame client stderrLast
    writeSocket client (encodeInt 1)
  27 -> do
    (paths, _) <- importPathsFrom store (readArchiveChunk client)
    writeFrame client stderrLast
    writeSocket client (encodeStrings paths)
  20 -> do
    settings <- readIORef settingsRef
    when (remote settings) (throwIO (storeError "Garbage collection is disabled for remote hosts."))
    action <- readIntSocket client
    paths <- readStorePathsSocket client
    ignoreLiveness <- readIntSocket client
    minFreed <- readWord64Socket client
    _obsolete1 <- readIntSocket client
    when (clientVersion .&. 0xffff >= 5) $ do
      _obsolete2 <- readIntSocket client
      _obsolete3 <- readIntSocket client
      pure ()
    when (ignoreLiveness == 1) (throwIO (storeError "you are not allowed to ignore liveness"))
    settings <- readIORef settingsRef
    (deleted, freed) <- withCollectorGCLock (storeGcLockPath config) $ do
      roots <- findRoots store
      withOtherTemporaryRoots (temporaryRootsPath config) rootFd $ \temporary -> do
        let rootPaths = map snd roots ++ temporary
        if action == 3
          then do
            live <- Collector.livePaths rootPaths store
            Collector.deleteSpecificPaths settings live paths minFreed store rootPath
          else do
            allPaths <- queryAllValidPaths store
            case action of
              -- C++ gcReturnLive / gcReturnDead return state.alive / state.dead,
              -- populated by canReachRoot, which honours gc-keep-outputs and
              -- gc-keep-derivations — not just the forward closure of the roots.
              0 -> do
                live <- Collector.livePathsWithSettings settings rootPaths store
                pure (live, 0)
              1 -> do
                live <- Collector.livePathsWithSettings settings rootPaths store
                pure (filter (`notElem` live) allPaths, 0)
              2 -> Collector.collectPaths settings rootPaths minFreed store rootPath
              _ -> throwIO (storeError "unsupported garbage-collection action")
    writeFrame client stderrLast
    writeSocket client (encodeStrings deleted <> encodeWord64 freed <> encodeWord64 0)
  -- C++ wopIsValidPath (nix-daemon.cc:315) is the ONE single-path op that
  -- reads with readString + assertStorePath, NOT readStorePath: it does not
  -- refuse reserved names, so querying a placeholder answers #f instead of
  -- an error (the ca-grafts unrealised-placeholder tests rely on this).
  1 -> do
    path <- readStringSocket client
    _ <- assertStorePath store path
    reply <- encodeBool <$> isValidPath store path
    writeFrame client stderrLast
    writeSocket client reply
  4 -> queryOnePath $ \_ path -> encodeString . encodeBase16 <$> queryPathHash store path
  5 -> queryOnePath $ \_ path -> encodeStrings <$> queryReferences store path
  6 -> queryOnePath $ \_ path -> encodeStrings <$> queryReferrers store path
  14 -> queryAll $ \_ -> encodeStringPairs <$> findRoots store
  18 -> queryOnePath $ \_ path -> encodeString <$> queryDeriver store path
  22 -> queryOnePath $ \_ path -> encodeStrings <$> queryDerivationOutputs store path
  23 -> queryAll $ \_ -> encodeStrings <$> queryAllValidPaths store
  24 -> queryAll $ \_ -> encodeStrings <$> queryFailedPaths store
  25 -> do
    paths <- readStorePathsSocket client
    clearFailedPaths store paths
    writeFrame client stderrLast
    writeSocket client (encodeInt 1)
  26 -> queryOnePath $ \_ path -> do
    info <- queryPathInfo store path
    pure (encodeString (infoDeriver info) <> encodeString (encodeBase16 (infoHash info))
      <> encodeStrings (infoReferences info) <> encodeInt (fromIntegral (infoRegistrationTime info))
      <> encodeWord64 (infoNarSize info))
  28 -> queryOnePath $ \_ path -> encodeStrings <$> queryDerivationOutputNames store path
  29 -> do
    hashPart <- readStringSocket client
    path <- queryPathFromHashPart store hashPart
    writeFrame client stderrLast
    writeSocket client (encodeString path)
  3 -> do
    path <- readStorePath store client
    settings <- readIORef settingsRef
    result <- if settingBool "build-use-substitutes" False settings
      then substitutablePaths config settings (stderrEmit client) [path] else pure []
    writeFrame client stderrLast
    writeSocket client (encodeBool (path `elem` result))
  30 -> do
    paths <- readStorePathsSocket client
    settings <- readIORef settingsRef
    infos <- if settingBool "build-use-substitutes" False settings
      then substitutableInfos config settings (stderrEmit client) paths else pure []
    writeFrame client stderrLast
    writeSocket client (encodeInt (fromIntegral (length infos)) <> foldMap encodeInfo infos)
  31 -> do
    paths <- readStorePathsSocket client
    result <- queryValidPaths store paths
    writeFrame client stderrLast
    writeSocket client (encodeStrings result)
  32 -> do
    paths <- readStorePathsSocket client
    settings <- readIORef settingsRef
    result <- if settingBool "build-use-substitutes" False settings
      then substitutablePaths config settings (stderrEmit client) paths else pure []
    writeFrame client stderrLast
    writeSocket client (encodeStrings result)
  33 -> queryOnePath $ \_ path -> encodeStrings <$> queryValidDerivers store path
  34 -> do
    paths <- queryAllValidPaths store
    mapM_ (deduplicateTree (storeDirectory store)) paths
    writeFrame client stderrLast
    writeSocket client (encodeInt 1)
  35 -> do
    checkContents <- (/= 0) <$> readIntSocket client
    repair <- (/= 0) <$> readIntSocket client
    settings <- readIORef settingsRef
    when (repair && not (trusted settings)) (throwIO (storeError "you are not privileged to repair paths"))
    paths <- queryAllValidPaths store
    errors <- Collector.verifyStorePaths checkContents repair (repairStorePath config rootFd store settings (stderrEmit client)) store paths
    writeFrame client stderrLast
    writeSocket client (encodeBool errors)
  80 -> do
    writeFrame client stderrLast
    writeSocket client (encodeStrings ["download", "git-download"])
  81 -> do
    settings <- readIORef settingsRef
    writeFrame client stderrLast
    writeSocket client (encodeStrings (substituteURLs settings))
  -- goonix: resolved-output and signed-record queries (HS-11).  No choice
  -- mutation in a query and no client registration (C++ nix-daemon.cc).
  82 -> do
    drvPath <- readStorePathStrict store client
    output <- readStringSocket client
    drv <- readDerivationFile drvPath
    path <- realisedOutputPath store drvPath drv output
    writeFrame client stderrLast
    writeSocket client (encodeString path)
  83 -> do
    resolvedHash <- readStringSocket client
    output <- readStringSocket client
    records <- queryRecords (database store) resolvedHash output
    writeFrame client stderrLast
    writeSocket client (encodeStrings (goonixRecordFields records False))
  84 -> do
    drvPath <- readStorePathStrict store client
    (records, hints) <- queryGoonixBuildGraphWithLog store (stderrEmit client) drvPath
    writeFrame client stderrLast
    writeSocket client (encodeStrings (goonixRecordFields records True) <> encodeStrings hints)
  _ -> throwIO (StoreError (C.pack ("invalid operation " ++ show operation)) 1)
  where
    readDerivationFile path = do
      bytes <- B.readFile (C.unpack path)
      either (throwIO . storeError) pure (parseDerivation bytes)
    encodeInfo (path, deriver, references, downloadSize, narSize) = encodeString path
      <> encodeString deriver <> encodeStrings references <> encodeWord64 downloadSize <> encodeWord64 narSize
    queryAll action = do
      reply <- action store
      writeFrame client stderrLast
      writeSocket client reply
    queryOnePath action = do
      path <- readStorePath store client
      reply <- action store path
      writeFrame client stderrLast
      writeSocket client reply

buildTrace :: Settings -> Socket -> BuildTrace
buildTrace settings client = BuildTrace
  { traceStarted = \drv platform log pid -> emit ("@ build-started " <> drv <> " - " <> platform <> " " <> log <> " " <> C.pack (show pid))
  , traceSucceeded = \drv -> emit ("@ build-succeeded " <> drv <> " -")
  , traceFailed = \drv reason -> emit ("@ build-failed " <> drv <> " - " <> C.pack reason)
  , traceOutput = \bytes ->
      -- C++ handleChildOutput sends builder output to the client only when
      -- verbosity >= buildVerbosity (build.cc).  Sending it unconditionally
      -- gives the client @ build-log lines for builds whose @ build-started
      -- trace it did not receive, and the client's status.scm update-build
      -- then fails on a missing build id.
      when (verbosity settings >= buildVerbosity settings) $
        writeSocket client (encodeInt stderrNext <> encodeString bytes)
  }
  where
    -- C++ printMsg_ appends "\n" to every trace message (util.cc), so each
    -- "@ build-..." line reaches the client terminated.  The client's
    -- build-event-output-port splits on newlines and drops the trailing one;
    -- without it, a build-started line runs into the following "@ build-log"
    -- header and its pid token parses as #f (guix-pack.sh crash).
    emit message = when (printBuildTrace settings) $ writeSocket client (encodeInt stderrNext <> encodeString (message <> "\n"))

-- | Forward a helper's diagnostics to the client as STDERR_NEXT frames, the way
-- the C++ daemon tunnels writeToStderr (nix-daemon.cc tunnelStderr).  Used for
-- the substituter's log pipe, which receiveLine drains in its select loop while
-- reading the reply.  Unlike the build trace this is not gated on
-- print-build-trace: C++ forwards substituter diagnostics unconditionally
-- (getLineFromSubstituter).
stderrEmit :: Socket -> ByteString -> IO ()
stderrEmit client bytes = writeSocket client (encodeInt stderrNext <> encodeString line)
  where
    -- Guix flushes STDERR_NEXT only when it contains a newline, as C++'s
    -- writeToStderr always does.  Do not leave a diagnostic buffered until
    -- after its HTTP response has been handled.
    line = if B.null bytes || B.last bytes == 10 then bytes else bytes <> "\n"

repairStorePath :: ServerConfig -> Fd -> Store -> Settings -> (ByteString -> IO ()) -> ByteString -> IO Bool
repairStorePath config rootFd store settings emit path = do
  substituted <- trySubstituteForRepair config rootFd store settings emit path
  if substituted then pure True else do
    deriver <- queryDeriver store path
    valid <- if B.null deriver then pure False else isValidPath store deriver
    if valid
      then do
        -- registerPath updates the existing valid entry after repair.
        buildThingsWithConfig config rootFd store settings (BuildTrace (\_ _ _ _ -> pure ()) (\_ -> pure ()) (\_ _ -> pure ()) emit) [deriver] Repair
        exists <- (Files.getSymbolicLinkStatus path >> pure True) `catchMissing` pure False
        registered <- isValidPath store path
        pure (exists && registered)
      else throwIO (storeError ("cannot repair path `" ++ C.unpack path ++ "'"))
  where
    trySubstituteForRepair config rootFd store settings emit path = do
      -- Repair must not use the ordinary valid-path shortcut: the object may
      -- be registered but absent or modified.  Re-fetch and register it.
      if not (settingBool "build-use-substitutes" False settings) then pure False else do
        infos <- substitutableInfos config settings emit [path]
        case infos of
          [] -> pure False
          ((_, deriver, references, _, _):_) -> do
            present <- mapM (isValidPath store) references
            if not (and present) then pure False else do
              appendTempRoot rootFd path
              result <- substitutePath config settings emit path path
              case result of
                Left _ -> pure False
                Right (printedHash, size) -> do
                  digest <- case C.break (== ':') printedHash of
                    ("sha256", encoded) -> either (throwIO . storeError) pure (decodeBase32 (B.drop 1 encoded))
                    _ -> throwIO (storeError "unsupported substitute hash")
                  (actualHash, actualSize) <- canonicaliseAndHash store path
                  if hashDigest actualHash /= digest
                    then deleteTree path >> pure False
                    else registerPath store path actualHash actualSize references deriver >> pure True

readSetOptions :: Socket -> Word32 -> IO [ByteString]
readSetOptions client clientVersion = do
  let minor = clientVersion .&. 0xff
      base :: Int
      base = 4 + (if minor < 0x61 then 2 else 0) + (if minor >= 2 then 1 else 0)
        + (if minor >= 4 then 3 else 0) + (if minor >= 6 && minor < 0x61 then 1 else 0)
        + (if minor >= 10 then 1 else 0)
  fields <- mapM (const (readExactly client 8)) [1 .. base]
  if minor >= 12
    then do
      count :: Int <- fromIntegral <$> readIntSocket client
      pairs <- mapM (const readPair) [1 .. count]
      pure (fields <> [encodeInt (fromIntegral count)] <> concat pairs)
    else pure fields
  where
    readPair = do
      key <- readStringSocket client
      value <- readStringSocket client
      pure [key, value]

readIntSocket :: Socket -> IO Word32
readIntSocket client = do
  bytes <- readExactly client 8
  case decodeInt bytes of
    Left message -> throwIO (StoreError message 1)
    Right value -> pure value

readWord64Socket :: Socket -> IO Word64
readWord64Socket client = do
  bytes <- readExactly client 8
  case decodeWord64 bytes of
    Left message -> throwIO (StoreError message 1)
    Right value -> pure value

readStringSocket :: Socket -> IO ByteString
readStringSocket client = do
  size <- fromIntegral <$> readIntSocket client
  when (size > 64 * 1024 * 1024) (throwIO (StoreError "wire string is too large" 1))
  let padded = size + paddingLength size
  contents <- readExactly client padded
  pure (B.take size contents)

readNarSocket :: Socket -> IO ByteString
readNarSocket client = do
  version <- readWireStringRaw
  when (B.length version < 16 || B.take 8 version /= encodeInt 13 || B.take 13 (B.drop 8 version) /= "nix-archive-1")
    (throwIO (storeError "invalid NAR header"))
  node <- readNarNode
  pure (version <> node)
  where
    readNarNode = do
      open <- readWireStringRaw
      typeTag <- readWireStringRaw
      kind <- readWireStringRaw
      when (B.take 8 open /= encodeInt 1 || B.take 8 typeTag /= encodeInt 4 || B.take 8 kind /= encodeInt (fromIntegral (B.length (wireValue kind)) :: Word32))
        (throwIO (storeError "invalid NAR node"))
      case wireValue kind of
        "regular" -> do
          first <- readWireStringRaw
          (executable, tag) <- if wireValue first == "executable"
            then do
              empty <- readWireStringRaw
              when (not (B.null (wireValue empty))) (throwIO (storeError "non-empty executable marker"))
              next <- readWireStringRaw
              pure (first <> empty, next)
            else pure (B.empty, first)
          when (wireValue tag /= "contents") (throwIO (storeError "invalid NAR contents"))
          lenBytes <- readExactly client 8
          let len = either (const 0) fromIntegral (decodeWord64 lenBytes) :: Int
          contents <- readExactly client (len + paddingLength len)
          close <- readWireStringRaw
          when (wireValue close /= ")") (throwIO (storeError "missing regular close"))
          pure (open <> typeTag <> kind <> executable <> tag <> lenBytes <> contents <> close)
        "symlink" -> do
          tag <- readWireStringRaw
          target <- readWireStringRaw
          close <- readWireStringRaw
          when (wireValue tag /= "target" || wireValue close /= ")") (throwIO (storeError "invalid symlink"))
          pure (open <> typeTag <> kind <> tag <> target <> close)
        "directory" -> do
          entries <- readDirectoryEntries
          pure (open <> typeTag <> kind <> entries)
        _ -> throwIO (storeError "unknown NAR node type")
    readDirectoryEntries = do
      tag <- readWireStringRaw
      if wireValue tag == ")" then pure tag else do
        open <- readWireStringRaw
        nameTag <- readWireStringRaw
        name <- readWireStringRaw
        nodeTag <- readWireStringRaw
        when (wireValue tag /= "entry" || wireValue open /= "(" || wireValue nameTag /= "name" || wireValue nodeTag /= "node")
          (throwIO (storeError "invalid directory entry"))
        child <- readNarNode
        close <- readWireStringRaw
        rest <- readDirectoryEntries
        pure (tag <> open <> nameTag <> name <> nodeTag <> child <> close <> rest)
    readWireStringRaw = do
      lenBytes <- readExactly client 8
      let len = either (const 0) fromIntegral (decodeInt lenBytes) :: Int
      bytes <- readExactly client (len + paddingLength len)
      pure (lenBytes <> bytes)
    wireValue bytes = B.take (either (const 0) fromIntegral (decodeInt (B.take 8 bytes))) (B.drop 8 bytes)

readArchiveChunk :: Socket -> IO ByteString
readArchiveChunk client = do
  writeSocket client (encodeInt stderrRead <> encodeInt 32768)
  lenBytes <- readExactly client 8
  len <- case decodeInt lenBytes of
    Left message -> throwIO (StoreError message 1)
    Right value -> pure (fromIntegral value)
  bytes <- readExactly client (len + paddingLength len)
  pure (B.take len bytes)

readStorePathsSocket :: Socket -> IO [ByteString]
readStorePathsSocket = readStringsSocket

-- | C++ readStorePath (store-api.cc:337): read one store path, asserting the
-- store prefix AND that it is not a goonix reserved name (placeholder/self
-- token).  The path-set reads (readStorePathsSocket) deliberately do NOT refuse
-- reserved names, matching C++ readStorePaths.  The Haskell daemon answers a
-- reserved path with a store error and keeps the connection (C++ rethrows while
-- parsing and drops it); the refusal itself is the parity requirement.
readStorePath :: Store -> Socket -> IO ByteString
readStorePath store client = do
  path <- readStringSocket client
  _ <- assertStorePath store path
  either (throwIO . storeError) pure (assertNotReserved (storeDirectory store) path)
  pure path

-- | C++ readStorePathStrict (store-api.cc:357): the strict single-path read.
readStorePathStrict :: Store -> Socket -> IO ByteString
readStorePathStrict store client = do
  path <- readStringSocket client
  _ <- assertStorePathStrict store path
  either (throwIO . storeError) pure (assertNotReserved (storeDirectory store) path)
  pure path

readStringsSocket :: Socket -> IO [ByteString]
readStringsSocket client = do
  count :: Int <- fromIntegral <$> readIntSocket client
  paths <- mapM (const (readStringSocket client)) [1 .. count]
  pure (foldr (\path rest -> if path `elem` rest then rest else path:rest) [] paths)

readExactly :: Socket -> Int -> IO ByteString
readExactly client size
  | size < 0 = throwIO (StoreError "negative read size" 1)
  | otherwise = go size []
  where
    go 0 chunks = pure (B.concat (reverse chunks))
    go remaining chunks = do
      chunk <- readSocket client (min remaining 65536)
      if B.null chunk then throwIO (userError "unexpected end-of-file")
        else go (remaining - B.length chunk) (chunk:chunks)

writeFrame :: Socket -> Word32 -> IO ()
writeFrame client frame = writeSocket client (encodeInt frame)

void :: IO a -> IO ()
void action = action >> pure ()
