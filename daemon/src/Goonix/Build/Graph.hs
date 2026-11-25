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
-- Complete replies are decoded and authenticated by Goonix.Store.CaStore, as
-- C++ does at build-goonix.inc:334 and local-store-ca.cc:195-284.  A refused
-- reply retries the next cache; the ordinary local build remains the fallback.
module Goonix.Build.Graph
  ( runGraphLookup
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, readMVar, tryPutMVar, tryReadMVar, withMVar)
import Control.Exception (SomeException, catch, finally, try)
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
import Goonix.Store.CaStore (importGoonixGraph)
import Goonix.Store.ReadOnly (Store)
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

data Answer = NoGraph | GraphAnswer ByteString

data GraphAgent = GraphAgent
  { graphPid :: ProcessID
  , graphInput :: Handle
  , graphLock :: MVar Bool
    -- ^ False until the single reaper has reaped the child.  Kill and the
    -- reaper's state update both hold this lock.
  , graphReaped :: MVar ()
  , graphAnswer :: MVar Answer
  }

-- | Try each cache as C++ GoonixGraphGoal::retry does.  A no-graph or refused
-- reply moves to the next cache.  Every path is local-build success.
runGraphLookup :: Fd -> Store -> Settings -> ByteString -> ByteString -> [ByteString]
               -> (ByteString -> IO ()) -> IO ()
runGraphLookup rootFd store settings guixProgram drvPath caches emit = go caches
  where
    go [] = pure ()
    go (cache:rest) = do
      started <- startOne cache `catch` \(_ :: SomeException) -> pure Nothing
      case started of
        Nothing -> go rest
        Just agent -> do
          answer <- (readMVar (graphAnswer agent)) `finally` stopGraphAgent agent
          case answer of
            GraphAnswer bytes -> do
              imported <- importGraphReply rootFd store drvPath bytes
              case imported of
                Right () -> emit ("goonix: graph sharing for `" <> drvPath <> "': answer imported\n")
                Left message -> do
                  emit ("goonix: graph cache for `" <> drvPath <> "': answer refused: "
                    <> C.pack message <> "\n")
                  go rest
            -- A helper can exit or close its reply pipe without answering.
            -- C++ retries the next configured cache instead of returning a
            -- non-exhaustive result to the scheduler.
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
          _ <- forkIO $ drainLog logRead emit
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

    drainLog handle emit = do
      let loop = do
            bytes <- fdRead handle 65536 `catch` \(_ :: SomeException) -> pure B.empty
            if B.null bytes then pure () else emit bytes >> loop
      loop
      closeFd handle `catch` \(_ :: SomeException) -> pure ()

    drainReply handle answer = do
      accumulated <- newIORef B.empty
      let loop = do
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
                    closeFd handle `catch` \(_ :: SomeException) -> pure ()
      loop

-- | Decode C++ goonixGraphReply: records precede hints; each field is an
-- independently hex-encoded byte string.  Hints remain advisory names until
-- importGoonixGraph finds a locally resolved, authenticated matching record.
importGraphReply :: Fd -> Store -> ByteString -> ByteString -> IO (Either String ())
importGraphReply rootFd store drvPath bytes = do
  result <- try $ case C.lines bytes of
    marker:countText:rest | marker == "goonix-records 1" ->
      case decimal countText of
        Just records -> case splitAt (records * 7) rest of
          (recordFields, hintCountText:hintFields) -> case decimal hintCountText of
            Just hints | length hintFields == hints * 3 -> do
              decoded <- traverse decodeHex (recordFields ++ hintFields)
              let (encodedRecords, encodedHints) = splitAt (records * 7) decoded
              offered <- traverse decodeRecord (chunksOf 7 encodedRecords)
              let choices = [ (original, output, path)
                            | [original, output, path] <- chunksOf 3 encodedHints ]
              importGoonixGraph rootFd store drvPath offered choices
            _ -> ioError (userError "graph reply has inconsistent field counts")
          _ -> ioError (userError "graph reply has inconsistent field counts")
        _ -> ioError (userError "invalid graph record count")
    _ -> ioError (userError "invalid graph response marker")
  pure $ case result of
    Left (exception :: SomeException) -> Left (show exception)
    Right () -> Right ()
  where
    decimal text = case C.readInteger text of
      Just (number, "") -> Just (fromInteger number :: Int)
      _ -> Nothing
    decodeRecord [hash, resolved, output, path, origin, checked, signature] =
      pure (hash, resolved, output, path, origin, checked == "1", signature)
    decodeRecord _ = ioError (userError "graph reply has inconsistent field counts")
    chunksOf _ [] = []
    chunksOf count values = take count values : chunksOf count (drop count values)
    decodeHex encoded
      | odd (B.length encoded) = ioError (userError "odd graph field encoding")
      | otherwise = B.pack <$> traverse decodeByte [0, 2 .. B.length encoded - 2]
      where
        decodeByte at = case (hexDigit (B.index encoded at), hexDigit (B.index encoded (at + 1))) of
          (Just high, Just low) -> pure (fromIntegral (high * 16 + low))
          _ -> ioError (userError "invalid graph field encoding")
    hexDigit byte
      | byte >= 48 && byte <= 57 = Just (fromIntegral byte - 48 :: Int)
      | byte >= 97 && byte <= 102 = Just (fromIntegral byte - 87)
      | byte >= 65 && byte <= 70 = Just (fromIntegral byte - 55)
      | otherwise = Nothing

-- | Nothing = a complete response has not arrived yet.  Just NoGraph means an
-- empty/invalid answer and Just GraphAnswer a complete non-empty one.  This is
-- the framing of parseGoonixGraphResponse (build-goonix-response.cc:7-39).
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
                        else Just (if records == 0 && hints == 0 then NoGraph else GraphAnswer bytes)
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
