{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import qualified Goonix.Config as Config
import Goonix.Store.Config
import Goonix.Store.GuixProgram (guixProgram, stateDirectory)
import Goonix.Store.Server
import Goonix.Store.Settings
import Goonix.Store.Socket (Socket)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Env.ByteString (getEnv)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (Handler (..), Signal, installHandler, raiseSignal, sigHUP, sigINT, sigTERM)

usage :: String
usage = unlines
    [ "Usage: guix-daemon [OPTION]..."
    , "Perform derivation builds and store accesses."
    , "  -c, --cores=N              use N CPU cores to build each derivation"
    , "  -M, --max-jobs=N           allow at most N build jobs"
    , "      --timeout=SECONDS      mark builds as failed after SECONDS"
    , "      --max-silent-time=SECONDS mark silent builds as failed"
    , "      --disable-chroot       disable chroot builds"
    , "      --chroot-directory=DIR add DIR to the build chroot"
    , "      --build-users-group=GROUP perform builds as a user of GROUP"
    , "      --no-substitutes       do not use substitutes"
    , "      --substitute-urls=URLS use URLS as substitute providers"
    , "      --no-offload           do not attempt to offload builds"
    , "      --cache-failures       cache build failures"
    , "      --rounds=N             build each derivation N times"
    , "      --lose-logs            do not keep build logs"
    , "      --log-compression=TYPE use none, gzip or bzip2 for build logs"
    , "      --discover[=yes/no]    discover local substitute servers"
    , "      --disable-deduplication disable automatic file deduplication"
    , "      --impersonate-linux-2.6 impersonate Linux 2.6"
    , "      --gc-keep-outputs[=yes/no] keep outputs of live derivations"
    , "      --gc-keep-derivations[=yes/no] keep live derivations"
    , "      --listen=SOCKET        listen for connections on SOCKET"
    , "      --debug                produce debugging output"
    , "      --isolate-host-loopback isolate fixed-output loopback"
    , "      --allow-aslr           allow ASLR"
    , "      --help                 display this help and exit"
    , "      --version              display version information and exit"
    ]

main :: IO ()
main = do
    args <- map C.pack <$> getArgs
    if args == ["--version"] || args == ["-V"]
        then putStrLn "guix-daemon (GNU Guix) 0.1.0.0"
        else if args == ["--help"] || args == ["--usage"]
            then putStr usage
            else do
                store <- storeDirectory args
                state <- stateDirectory
                database <- databasePath state
                guix <- guixProgram
                case parseDaemonOptions args of
                    Left message -> hPutStrLn stderr message >> exitFailure
                    Right options -> do
                        let config = defaultConfig
                              { configStore = store
                              , configDatabase = database
                              , configDefaultSettings = settings options
                              , configStateDirectory = state
                              , configGuixProgram = guix
                              }
                        lifecycle <- newLifecycle
                        stoppedBy <- catchTerminationSignals lifecycle
                        when (settingBool "build-discover" False (configDefaultSettings config)) $
                          startDiscovery (configGuixProgram config)
                        activated <- activationSockets
                        case activated of
                            [] -> case listenOptions options of
                                [] -> serve config lifecycle
                                [socket] -> serveSocket config lifecycle socket
                                sockets -> serveManyPaths config lifecycle sockets
                            listeners -> serveMany config lifecycle listeners
                        readIORef stoppedBy >>= mapM_ endBySignal

-- | SIGTERM, SIGINT and SIGHUP ask the daemon to stop: it accepts no further
-- client, serves the connected ones until each has disconnected, and then
-- ends.  The C++ daemon leaves all three at their default action in its
-- listening process, so they end that process at once, and catches all three
-- in its per-client processes (nix-daemon.cc, setTerminationSignalHandler);
-- those run in sessions of their own, where a signal for the listening
-- process does not reach them, and serve their clients to the end.  One
-- process cannot both end at once and keep serving, so this one keeps
-- serving.  The first of the signals is remembered: the process ends by it.
--
-- A signal that was being ignored when the daemon started stays ignored, as
-- it does in the C++ listening process.
catchTerminationSignals :: Lifecycle -> IO (IORef (Maybe Signal))
catchTerminationSignals lifecycle = do
    stoppedBy <- newIORef Nothing
    forM_ [sigTERM, sigINT, sigHUP] $ \signal -> do
        ignored <- c_ignored_at_start signal
        installHandler signal
            (if ignored /= 0 then Ignore else Catch (stopOn stoppedBy signal)) Nothing
    pure stoppedBy
  where
    stopOn stoppedBy signal = do
        first <- requestStop lifecycle
        when first $ do
            atomicModifyIORef' stoppedBy (const (Just signal, ()))
            clients <- openConnections lifecycle
            -- Say why the process is still there.  With no client it ends as
            -- silently as the C++ listening process does.
            when (clients > 0) $ do
                pid <- getProcessID
                hPutStrLn stderr ("guix-daemon: PID " ++ show pid ++ " caught signal "
                    ++ show signal ++ "; accepting no more clients, ending when the "
                    ++ show clients ++ " connected have finished")

-- | End the way the C++ listening process does: by the signal, with its
-- default action, so that whoever waits for this process sees the same
-- status.
endBySignal :: Signal -> IO ()
endBySignal signal = do
    void (installHandler signal Default Nothing)
    raiseSignal signal

foreign import ccall unsafe "goonix_ignored_at_start"
  c_ignored_at_start :: CInt -> IO CInt

foreign import ccall unsafe "goonix_spawn_discover"
  c_spawn_discover :: CString -> Ptr CInt -> IO CInt

startDiscovery :: B.ByteString -> IO ()
startDiscovery program = do
  result <- B.useAsCString program $ \program' -> alloca $ \pidPointer -> do
    status <- c_spawn_discover program' pidPointer
    if status < 0 then pure (-1) else fromIntegral <$> peek pidPointer
  when (result < (0 :: Int)) $ ioError (userError "cannot spawn guix discover")
  -- The C++ daemon does not wait for the discovery process.
  pure ()

-- | Serve several listening sockets.  A listener that fails ends the daemon.
-- A listener returns without failing only when the daemon has been asked to
-- stop, and then all of them have to return: each waits for the clients.
serveMany :: ServerConfig -> Lifecycle -> [Socket] -> IO ()
serveMany config lifecycle listeners = do
    done <- newEmptyMVar
    forM_ listeners $ \listener -> forkIO $ do
        result <- try (serveListener config lifecycle listener)
        case result of
            Left exception -> hPutStrLn stderr (show (exception :: SomeException)) >> putMVar done False
            Right _ -> putMVar done True
    let wait :: Int -> IO ()
        wait 0 = pure ()
        wait remaining = do
            stopped <- takeMVar done
            when stopped (wait (remaining - 1))
    wait (length listeners)

serveManyPaths :: ServerConfig -> Lifecycle -> [B.ByteString] -> IO ()
serveManyPaths config lifecycle paths = do
    -- Open every listener FIRST, one after another, before any accept loop is
    -- forked (as the C++ daemon opens all its sockets before serving).  Binding
    -- a Unix socket mutates the process-wide umask and working directory
    -- (goonix_listen_unix chdir-binds the relative name under umask(0111));
    -- doing it inside a forkIO per path let two binds race — one could bind
    -- ./socket in the other's directory, and another thread's mkdir in the
    -- umask window could create directories without x bits.  Sequential opens
    -- remove that race; only the accept loops run concurrently.
    listeners <- mapM openListener paths
    serveMany config lifecycle listeners

storeDirectory :: [B.ByteString] -> IO B.ByteString
storeDirectory args = do
    env <- getEnv "NIX_STORE_DIR"
    nixStore <- getEnv "NIX_STORE"
    pure (optionValue "--store=" args `orElse` env `orElse` nixStore `orElse` Just (C.pack Config.storeDirectory) `withDefault` C.pack Config.storeDirectory)

-- | C++ globals.cc:65: nixDBPath = getEnv("GUIX_DATABASE_DIRECTORY",
-- nixStateDir + "/db"), then the db.sqlite file inside it.  GUIX_DATABASE_PATH
-- is an extra explicit override.  The state directory is already resolved
-- (GUIX_STATE_DIRECTORY else configure-time), so no NIX_STATE_DIR re-read.
databasePath :: B.ByteString -> IO FilePath
databasePath state = do
    explicit <- getEnv "GUIX_DATABASE_PATH"
    directory <- getEnv "GUIX_DATABASE_DIRECTORY"
    let dbDir = directory `orElse` Just (state <> "/db")
    pure (C.unpack (explicit `orElse` fmap (<> "/db.sqlite") dbDir `withDefault` C.pack (Config.stateDirectory ++ "/db/db.sqlite")))

optionValue :: B.ByteString -> [B.ByteString] -> Maybe B.ByteString
optionValue _ [] = Nothing
optionValue prefix (arg:rest)
    | B.isPrefixOf prefix arg = Just (B.drop (B.length prefix) arg)
    | otherwise = optionValue prefix rest

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just value) _ = Just value
orElse Nothing other = other

withDefault :: Maybe a -> a -> a
withDefault (Just value) _ = value
withDefault Nothing fallback = fallback
