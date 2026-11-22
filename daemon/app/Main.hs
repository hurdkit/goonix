{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import qualified Goonix.Config as Config
import Goonix.Store.Config
import Goonix.Store.GuixProgram (guixProgram)
import Goonix.Store.Server
import Goonix.Store.Settings
import Goonix.Store.Socket (Socket)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Env.ByteString (getEnv)

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
                database <- databasePath
                state <- getEnv "GUIX_STATE_DIRECTORY"
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
                        when (settingBool "build-discover" False (configDefaultSettings config)) $
                          startDiscovery (configGuixProgram config)
                        activated <- activationSockets
                        case activated of
                            [] -> case listenOptions options of
                                [] -> serve config
                                [socket] -> serveSocket config socket
                                sockets -> serveManyPaths config sockets
                            listeners -> serveMany config listeners

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

serveMany :: ServerConfig -> [Socket] -> IO ()
serveMany config listeners = do
    done <- newEmptyMVar
    forM_ listeners $ \listener -> forkIO $ do
        result <- try (serveListener config listener)
        case result of
            Left exception -> hPutStrLn stderr (show (exception :: SomeException))
            Right _ -> pure ()
        putMVar done ()
    takeMVar done

serveManyPaths :: ServerConfig -> [B.ByteString] -> IO ()
serveManyPaths config paths = do
    -- Open every listener FIRST, one after another, before any accept loop is
    -- forked (as the C++ daemon opens all its sockets before serving).  Binding
    -- a Unix socket mutates the process-wide umask and working directory
    -- (goonix_listen_unix chdir-binds the relative name under umask(0111));
    -- doing it inside a forkIO per path let two binds race — one could bind
    -- ./socket in the other's directory, and another thread's mkdir in the
    -- umask window could create directories without x bits.  Sequential opens
    -- remove that race; only the accept loops run concurrently.
    listeners <- mapM openListener paths
    done <- newEmptyMVar
    forM_ listeners $ \listener -> forkIO $ do
        result <- try (serveListener config listener)
        case result of
            Left exception -> hPutStrLn stderr (show (exception :: SomeException))
            Right _ -> pure ()
        putMVar done ()
    takeMVar done

storeDirectory :: [B.ByteString] -> IO B.ByteString
storeDirectory args = do
    env <- getEnv "NIX_STORE_DIR"
    nixStore <- getEnv "NIX_STORE"
    pure (optionValue "--store=" args `orElse` env `orElse` nixStore `orElse` Just (C.pack Config.storeDirectory) `withDefault` C.pack Config.storeDirectory)

databasePath :: IO FilePath
databasePath = do
    explicit <- getEnv "GUIX_DATABASE_PATH"
    directory <- getEnv "GUIX_DATABASE_DIRECTORY"
    state <- getEnv "NIX_STATE_DIR"
    pure (C.unpack (explicit `orElse` fmap (<> "/db.sqlite") directory `orElse` fmap (<> "/db/db.sqlite") state `orElse` Just (C.pack (Config.stateDirectory ++ "/db/db.sqlite")) `withDefault` C.pack (Config.stateDirectory ++ "/db/db.sqlite")))

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
