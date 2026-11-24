{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | HS-11: asynchronous, untrusted build-record lookup, C++ GoonixGraphGoal
-- (nix/libstore/build-goonix.inc:199-341).
--
-- A lookup is a scheduler job that consumes NO build slot.  While it waits,
-- another goal can build with --max-jobs=1.  Its deadline starts when the
-- helper starts (build-goonix.inc:268-270), not when a builder resumes.
--
-- Exactly one thread reaps each helper.  Killing and reaping hold the same
-- lock.  waitid(WNOWAIT) observes exit before the lock excludes the killer;
-- the single waitpid then releases the still-owned pid.  An empty reply
-- retries the next cache (build-goonix.inc:323-332).
--
-- Scope: this module performs queries and enforces their lifecycle.  It does
-- NOT yet import authenticated graph answers.  C++ parses/imports them at
-- build-goonix.inc:311-341 and local-store-ca.cc:195-284; that remains an open
-- HS-11 item, not working functionality claimed here.
module Goonix.Build.Graph
  ( runGraphLookup
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, readMVar, tryPutMVar, tryReadMVar, withMVar)
import Control.Exception (SomeException, catch, finally)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef (newIORef, readIORef, writeIORef)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import Goonix.Store.Settings (Settings, settingInt)
import Goonix.Store.Substitute (packSettings)
import System.IO (Handle, hClose, hFlush)
import System.Posix.IO.ByteString (createPipe, closeFd, fdToHandle, setFdOption, FdOption (CloseOnExec), fdRead)
import System.Posix.Process (getProcessStatus)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Posix.Types (CPid (..), Fd (..), ProcessID)

foreign import ccall safe "goonix_waitid_nowait"
  c_waitid_nowait :: CPid -> IO CInt

foreign import ccall unsafe "goonix_spawn_helper"
  c_spawn_helper :: CString -> CString -> CInt -> CInt -> CInt -> CString -> Ptr CInt -> IO CInt

data Answer = NoGraph | GraphAnswer deriving (Eq, Show)

data GraphAgent = GraphAgent
  { graphPid :: ProcessID
  , graphInput :: Handle
  , graphLock :: MVar Bool
    -- ^ False until the single reaper has reaped the child.  Kill and the
    -- reaper's state update both hold this lock.
  , graphReaped :: MVar ()
  , graphAnswer :: MVar Answer
  }

-- | Try each cache as C++ GoonixGraphGoal::retry does.  A usable answer is not
-- imported yet (see the module's explicit scope note); an empty/no-graph reply
-- moves to the next cache.  Every path is local-build success, never a failure.
runGraphLookup :: Settings -> ByteString -> ByteString -> [ByteString]
               -> (ByteString -> IO ()) -> IO ()
runGraphLookup settings guixProgram drvPath caches emit = go caches
  where
    go [] = pure ()
    go (cache:rest) = do
      started <- startOne cache `catch` \(_ :: SomeException) -> pure Nothing
      case started of
        Nothing -> go rest
        Just agent -> do
          answer <- (readMVar (graphAnswer agent)) `finally` stopGraphAgent agent
          case answer of
            GraphAnswer -> pure ()
            NoGraph -> go rest

    startOne cache = do
      (inputRead, inputWrite) <- createPipe
      (logRead, logWrite) <- createPipe
      (replyRead, replyWrite) <- createPipe
      mapM_ (\fd -> setFdOption fd CloseOnExec True)
        [inputRead, inputWrite, logRead, logWrite, replyRead, replyWrite]
      pid <- withCString (C.unpack guixProgram) $ \program ->
        withCString "--goonix-graph" $ \argument ->
          B.useAsCString (packSettings settings) $ \options -> alloca $ \pidPointer -> do
            result <- c_spawn_helper program argument (fdNumber inputRead)
              (fdNumber logWrite) (fdNumber replyWrite) options pidPointer
            if result < 0 then pure 0 else fromIntegral <$> peek pidPointer
      closeFd inputRead
      closeFd logWrite
      closeFd replyWrite
      if pid == 0
        then do
          mapM_ closeFd [inputWrite, logRead, replyRead]
          pure Nothing
        else do
          input <- fdToHandle inputWrite
          C.hPutStrLn input ("records " <> drvPath <> " " <> cache)
          hFlush input
          lock <- newMVar False
          reaped <- newEmptyMVar
          answer <- newEmptyMVar
          let agent = GraphAgent pid input lock reaped answer
              kill = withMVar lock $ \alreadyReaped ->
                when (not alreadyReaped) $
                  signalProcess sigKILL pid `catch` \(_ :: SomeException) -> pure ()
          _ <- forkIO $ drainLog logRead
          _ <- forkIO $ drainReply replyRead answer
          _ <- forkIO $ do
            threadDelay (settingInt "build-graph-timeout" 15 settings * 1000000)
            settled <- tryReadMVar answer
            case settled of
              Just _ -> pure ()
              Nothing -> do
                emit ("goonix graph query for `" <> drvPath
                  <> "' reached its graph cache deadline\n")
                kill
          -- The ONLY reaper.  WNOWAIT observes exit without releasing the
          -- pid.  Only after the lock excludes the killer do we waitpid.
          _ <- forkIO $ do
            _ <- c_waitid_nowait pid
            _ <- withMVar lock (const (getProcessStatus True False pid))
            void (tryPutMVar answer NoGraph)
            putMVar reaped ()
          pure (Just agent)

    drainLog handle = do
      let loop = do
            bytes <- fdRead handle 65536 `catch` \(_ :: SomeException) -> pure B.empty
            if B.null bytes then pure () else loop
      loop
      closeFd handle `catch` \(_ :: SomeException) -> pure ()

    drainReply handle answer = do
      accumulated <- newIORef B.empty
      let tailLoop = do
            chunk <- fdRead handle 65536 `catch` \(_ :: SomeException) -> pure B.empty
            if B.null chunk then pure () else tailLoop
          loop = do
            chunk <- fdRead handle 65536 `catch` \(_ :: SomeException) -> pure B.empty
            if B.null chunk
              then do
                void (tryPutMVar answer NoGraph)
                closeFd handle `catch` \(_ :: SomeException) -> pure ()
              else do
                previous <- readIORef accumulated
                let bytes = previous <> chunk
                writeIORef accumulated bytes
                case responseStatus bytes of
                  Nothing -> loop
                  Just result -> do
                    void (tryPutMVar answer result)
                    -- Drain through EOF so the server's close event is logged.
                    tailLoop
                    closeFd handle `catch` \(_ :: SomeException) -> pure ()
      loop

-- | Nothing = a complete response has not arrived yet.  Just NoGraph means an
-- empty/invalid answer and Just GraphAnswer a non-empty one.  This is the
-- framing of parseGoonixGraphResponse (build-goonix-response.cc:7-39), used
-- here only for lifecycle and retry; the payload is not adopted.
responseStatus :: ByteString -> Maybe Answer
responseStatus bytes
  | B.length bytes > 128 * 1024 * 1024 = Just NoGraph
  | B.null bytes = Nothing
  | otherwise = case C.lines bytes of
      [] -> Just NoGraph
      marker:rest
        | marker /= "goonix-records 1" -> Just NoGraph
        | otherwise -> case rest of
            [] -> Nothing
            countText:fields -> case decimal countText of
              Nothing -> Just NoGraph
              Just records | records > 100000 -> Just NoGraph
              Just records ->
                let hintIndex = records * 7
                in if length fields <= hintIndex
                  then Nothing
                  else case decimal (fields !! hintIndex) of
                    Nothing -> Just NoGraph
                    Just hints | hints > 100000 -> Just NoGraph
                    Just hints ->
                      let remaining = fields !! hintIndex : drop (hintIndex + 1) fields
                      in if length remaining < 1 + hints * 3 || not (B.isSuffixOf "\n" bytes)
                        then Nothing
                        else Just (if records == 0 && hints == 0 then NoGraph else GraphAnswer)
  where
    decimal text = case C.readInteger text of
      Just (number, "") -> Just (fromInteger number :: Int)
      _ -> Nothing

stopGraphAgent :: GraphAgent -> IO ()
stopGraphAgent agent = do
  hClose (graphInput agent) `catch` \(_ :: SomeException) -> pure ()
  withMVar (graphLock agent) $ \reaped ->
    when (not reaped) $
      signalProcess sigKILL (graphPid agent) `catch` \(_ :: SomeException) -> pure ()
  -- The reaper alone calls waitpid.  Waiting here is only for its completion,
  -- not a second getProcessStatus and never an ECHILD race.
  readMVar (graphReaped agent)

fdNumber :: Fd -> CInt
fdNumber (Fd value) = value
