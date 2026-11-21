{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE StrictData #-}
module Main where
import Control.Monad (when)
import Network.Socket
import System.Environment (getArgs, setEnv)
import System.Posix.Process (executeFile, getProcessID)
import System.Posix.IO (setFdOption, FdOption (..), dupTo)
import System.Posix.Types (Fd (..))
import System.Directory (createDirectoryIfMissing, removeFile)
import System.Posix.Files (fileExist)
main :: IO ()
main = getArgs >>= \case
  [socketPath, daemon, store, db] -> activate socketPath daemon store db
  _ -> error "usage: Activate SOCKET DAEMON STORE DATABASE"

activate :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
activate socketPath daemon store db = do
  createDirectoryIfMissing True (reverse (dropWhile (/= '/') (reverse socketPath)))
  exists <- fileExist socketPath
  if exists then removeFile socketPath else pure ()
  listener <- socket AF_UNIX Stream defaultProtocol
  bind listener (SockAddrUnix socketPath)
  listen listener 16
  fd <- socketToFd listener
  when (fd /= 3) $ do
    _ <- dupTo (Fd fd) (Fd 3)
    pure ()
  setFdOption (Fd 3) CloseOnExec False
  pid <- getProcessID
  setEnv "LISTEN_PID" (show pid)
  setEnv "LISTEN_FDS" "1"
  setEnv "NIX_STORE_DIR" store
  setEnv "GUIX_DATABASE_PATH" db
  setEnv "GUIX_DAEMON_SOCKET" socketPath
  executeFile daemon False ["--disable-chroot", "--substitute-urls=file:///tmp/goonix-substitute"] Nothing
