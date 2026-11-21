{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- GNU Guix --- Functional package management for GNU
-- This file is part of GNU Guix.
-- GNU Guix is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version.

module Main (main) where

import Control.Concurrent (MVar, forkOS, newEmptyMVar, putMVar, takeMVar)
import Control.Exception
    ( bracket, finally, handle, onException, throwIO )
import GHC.IO.Exception (IOErrorType (EOF), ioe_type)
import Control.Monad (unless, when)
import Data.Bits ((.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Char8 as Char8
import Data.Foldable (for_)
import Data.Word (Word32)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (CInt))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (withArray0)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (hPutStrLn, stderr)
import System.Posix.Directory.ByteString (closeDirStream, openDirStream, readDirStream)
import System.Posix.Env.ByteString (getArgs, getEnvironment)
import System.Posix.IO.ByteString
    ( OpenFileFlags (..), OpenMode (WriteOnly), closeFd, createPipe, defaultFileFlags
    , fdRead, fdWrite, openFd, setFdOption, FdOption (CloseOnExec) )
import System.Posix.Process (ProcessStatus (Exited), getProcessStatus)
import System.Posix.Types (Fd, ProcessID)
import System.Posix.User (getRealGroupID, getRealUserID)

foreign import ccall unsafe "p2_posix_spawn"
    c_spawn :: CString -> Ptr CString -> Ptr CString -> Ptr CInt
            -> CInt -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "p2_unshare_user" c_unshareUser :: IO CInt

setSid, closeFds, newUserNs, chdirFlag, stdinFile, noNewPrivs :: Word32
setSid = 2
closeFds = 4
newUserNs = 8
chdirFlag = 32
stdinFile = 64
noNewPrivs = 512

data Plan = Plan
    { flags :: Word32
    , program :: ByteString
    , arguments :: [ByteString]
    , environment :: [(ByteString, ByteString)]
    , workingDirectory :: ByteString
    , inputFile :: ByteString
    , userId :: Word32
    , groupId :: Word32
    , inputFd :: Int
    , logFd :: Int
    , supplementaryGroups :: [Word32]
    , earlyCloseFds :: [Word32]
    , uidMapInside :: Word32
    , uidMapOutside :: Word32
    , gidMapInside :: Word32
    , gidMapOutside :: Word32
    }

initialPlan :: Plan
initialPlan = Plan
    { flags = 0
    , program = ""
    , arguments = []
    , environment = []
    , workingDirectory = ""
    , inputFile = ""
    , userId = 0
    , groupId = 0
    , inputFd = -1
    , logFd = -1
    , supplementaryGroups = []
    , earlyCloseFds = []
    , uidMapInside = 0
    , uidMapOutside = 0
    , gidMapInside = 0
    , gidMapOutside = 0
    }

u32 :: Word32 -> Builder.Builder
u32 = Builder.word32LE

bytes :: ByteString -> Builder.Builder
bytes value = u32 (fromIntegral (BS.length value)) <> Builder.byteString value

fdNumber :: Int -> Word32
fdNumber value = if value < 0 then maxBound else fromIntegral value

encodePlan :: Plan -> ByteString
encodePlan plan = LBS.toStrict $ Builder.toLazyByteString $
    Builder.byteString (BS.pack [71, 83, 80, 48, 48, 48, 49, 0])
    <> u32 (flags plan)
    <> bytes (program plan)
    <> u32 (fromIntegral (length (arguments plan)))
    <> foldMap bytes (arguments plan)
    <> u32 (fromIntegral (length (environment plan)))
    <> foldMap (\(name, value) -> bytes name <> bytes value) (environment plan)
    <> bytes (workingDirectory plan)
    <> bytes (inputFile plan)
    <> u32 (userId plan) <> u32 (groupId plan)
    <> u32 (fdNumber (inputFd plan)) <> u32 (fdNumber (logFd plan))
    <> u32 (fromIntegral (length (supplementaryGroups plan)))
    <> foldMap u32 (supplementaryGroups plan)
    <> u32 (fromIntegral (length (earlyCloseFds plan)))
    <> foldMap u32 (earlyCloseFds plan)
    <> u32 (uidMapInside plan) <> u32 (uidMapOutside plan)
    <> u32 (gidMapInside plan) <> u32 (gidMapOutside plan)
    <> bytes "" <> u32 0

writeAll :: Fd -> ByteString -> IO ()
writeAll fd value = unless (BS.null value) $ do
    written <- fdWrite fd value
    when (written <= 0) (throwIO (userError "short write to plan"))
    writeAll fd (BS.drop (fromIntegral written) value)

writePlan :: ByteString -> Plan -> IO ()
writePlan path plan = bracket
    (openFd path WriteOnly defaultFileFlags
        { creat = Just 0o600, trunc = True, cloexec = True })
    closeFd
    (\fd -> writeAll fd (encodePlan plan))

readAll :: Fd -> IO ByteString
readAll fd = go []
  where
    go chunks = handle (atEof chunks) $ do
        chunk <- fdRead fd 4096
        if BS.null chunk
            then pure (BS.concat (reverse chunks))
            else go (chunk : chunks)
    atEof chunks exception
        | ioe_type exception == EOF = pure (BS.concat (reverse chunks))
        | otherwise = throwIO exception

withCStrings :: [ByteString] -> ([CString] -> IO a) -> IO a
withCStrings values action = go values []  where
    go [] pointers = action (reverse pointers)
    go (value : rest) pointers = BS.useAsCString value
        (\pointer -> go rest (pointer : pointers))

withCStringArray :: [ByteString] -> (Ptr CString -> IO a) -> IO a
withCStringArray values action = withCStrings values (\pointers -> withArray0 nullPtr pointers action)

spawnHelper :: ByteString -> ByteString -> IO (ByteString, ByteString, ProcessStatus)
spawnHelper helper planPath = do
    (outputRead, outputWrite) <- createPipe
    (errorRead, errorWrite) <- createPipe
    mapM_ (\fd -> setFdOption fd CloseOnExec True)
        [outputWrite, errorWrite]
    inherited <- getEnvironment
    let env = map (\(name, value) -> name <> "=" <> value) inherited
    let argv = [helper, planPath]
    result <- withCStringArray argv $ \argvPtr ->
        withCStringArray env $ \envPtr ->
        BS.useAsCString helper $ \programPtr ->
        alloca $ \pidPtr -> do
            rc <- c_spawn programPtr argvPtr envPtr pidPtr (-1)
                (fromIntegral outputWrite) (fromIntegral errorWrite)
            if rc /= 0
                then pure (Left rc)
                else Right <$> peek pidPtr
    closeFd outputWrite
    closeFd errorWrite
    case result of
        Left rc -> do
            closeFd outputRead
            closeFd errorRead
            throwIO (userError ("posix_spawn failed with errno " ++ show rc))
        Right rawPid -> do
            (output, errors) <- finally
                (onException
                    ((,) <$> readAll outputRead <*> readAll errorRead)
                    (waitChild rawPid))
                (closeFd outputRead >> closeFd errorRead)
            status <- getProcessStatus True False (fromIntegral rawPid :: ProcessID)
            case status of
                Nothing -> throwIO (userError "waitpid returned no child status")
                Just value -> pure (output, errors, value)
  where
    waitChild rawPid = do
        _ <- getProcessStatus True False (fromIntegral rawPid :: ProcessID)
        pure ()

check :: String -> Bool -> IO ()
check label condition = unless condition (throwIO (userError ("check failed: " ++ label)))

runPlan :: String -> ByteString -> ByteString -> Plan -> [ByteString] -> IO ByteString
runPlan label helper work plan expected = do
    let path = work <> "/" <> pack label <> ".plan"
    writePlan path plan
    (output, errors, status) <- spawnHelper helper path
    BS.putStr output
    unless (BS.null errors) (BS.hPutStr stderr errors)
    check (label ++ " child exit status") (status == Exited ExitSuccess)
    for_ expected $ \needle -> check (label ++ ": " ++ show needle) (needle `BS.isInfixOf` output)
    pure output

countRuntimeThreads :: IO Int
countRuntimeThreads = bracket (openDirStream "/proc/self/task") closeDirStream (go 0)
  where
    go total stream = do
        entry <- readDirStream stream
        if BS.null entry then pure total
        else if entry == "." || entry == ".." then go total stream
        else go (total + 1) stream

directUnshareFromThreadedRuntime :: IO (Int, Int)
directUnshareFromThreadedRuntime = do
    stop <- newEmptyMVar :: IO (MVar ())
    started <- newEmptyMVar :: IO (MVar ())
    _ <- forkOS (putMVar started () >> takeMVar stop)
    takeMVar started
    (threads, result) <- finally
        (do
            count <- countRuntimeThreads
            result <- fromIntegral <$> c_unshareUser
            when (result == 0) (throwIO (userError "direct unshare unexpectedly succeeded"))
            pure (count, result))
        (putMVar stop ())
    pure (result, threads)

pack :: String -> ByteString
pack = Char8.pack

main :: IO ()
main = do
    args <- getArgs
    case args of
        [helper, work, child] -> do
            hostUid <- fromIntegral <$> getRealUserID
            hostGid <- fromIntegral <$> getRealGroupID
            let input = work <> "/input"
            writeAllFile input "probe-input\n"
            let common = initialPlan
                    { flags = setSid .|. closeFds .|. chdirFlag .|. stdinFile .|. noNewPrivs
                    , program = child
                    , workingDirectory = work
                    , inputFile = input
                    }
            let basic = common
                    { arguments = [child, "argument with spaces", BS.pack [255, 88]]
                    , environment = [("P2_VALUE", "basic-value")]
                    }
            _ <- runPlan "basic" helper work basic
                [ "argc=3\n", "arg1=argument with spaces\n"
                , "arg2=" <> BS.pack [255, 88] <> "\n"
                , "env=basic-value\n", "cwd=" <> work <> "\n"
                , "uid=" <> decimal hostUid <> " euid=" <> decimal hostUid
                , "gid=" <> decimal hostGid <> " egid=" <> decimal hostGid
                , "session-is-leader=1\n", "no-new-privs=1\n"
                , "extra-fds=0\n", "stdin=probe-input\n"
                ]
            (unshareError, threads) <- directUnshareFromThreadedRuntime
            hPutStrLn stderr ("direct unshare errno=" ++ show unshareError
                ++ ", runtime threads=" ++ show threads)
            check "probe is threaded" (threads > 1)
            check "threaded unshare is rejected with EINVAL" (unshareError == 22)
            let namespaced = common
                    { flags = flags common .|. newUserNs
                    , arguments = [child, "namespace"]
                    , environment = [("P2_VALUE", "namespace")]
                    , uidMapOutside = hostUid
                    , gidMapOutside = hostGid
                    }
            _ <- runPlan "namespace" helper work namespaced
                [ "env=namespace\n", "uid=0 euid=0 gid=0 egid=0\n"
                , "uid_map=0 " <> decimal hostUid <> " 1\n"
                , "gid_map=0 " <> decimal hostGid <> " 1\n"
                , "session-is-leader=1\n", "extra-fds=0\n"
                , "stdin=probe-input\n", "namespace-ready=1\n"
                ]
            pure ()
        _ -> throwIO (userError "usage: ThreadedUnshareProbe GUIX_SANDBOX WORK_DIR CHILD_INSPECT")
  where
    decimal value = pack (show (value :: Word32))

writeAllFile :: ByteString -> ByteString -> IO ()
writeAllFile path value = bracket
    (openFd path WriteOnly defaultFileFlags
        { creat = Just 0o600, trunc = True, cloexec = True })
    closeFd
    (\fd -> writeAll fd value)
