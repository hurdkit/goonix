{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

module Goonix.Store.Collector
  ( livePaths
  , GCLimitReached (..)
  , collectPaths
  , deleteSpecificPaths
  , verifyStorePaths
  ) where

import Control.Exception (Exception, IOException, SomeException, handle, throwIO, try)
import Data.Typeable (Typeable)
import Control.Monad (foldM, forM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Set as Set
import Data.Word (Word64)
import Goonix.Store.Database (Value (Bytes, Integer), execute, withTransaction)
import Goonix.Store.Hash (HashAlgorithm (SHA256))
import Goonix.Store.Files (deleteTree, withGCLock, announcedRoots, storeGcLockPathOf)
import Goonix.Store.Hash (hashDigest)
import Goonix.Store.Nar (hashNar, dumpNar)
import Goonix.Store.ReadOnly
import Goonix.Store.Settings (Settings, settingBool)
import System.IO.Error (isDoesNotExistError)
import qualified System.Posix.Files.ByteString as Files

livePaths :: [ByteString] -> Store -> IO [ByteString]
livePaths roots store = Set.toAscList <$> go Set.empty roots
  where
    go seen [] = pure seen
    go seen (path:rest)
      | Set.member path seen = go seen rest
      | otherwise = do
          valid <- isValidPath store path
          if not valid then go seen rest else do
            references <- queryReferences store path
            go (Set.insert path seen) (references ++ rest)

-- Memoized reverse reachability.  A path reached only through the current
-- recursion stack is not live; a known-live incoming edge makes it live.
data Reachability = Reachability
  { liveSet :: !(Set.Set ByteString)
  , deadSet :: !(Set.Set ByteString)
  }

canReachRoot :: Settings -> Set.Set ByteString -> Store -> Reachability
  -> ByteString -> IO (Reachability, Bool)
canReachRoot settings roots store = go
  where
    keepOutputs = settingBool "gc-keep-outputs" False settings
    keepDerivations = settingBool "gc-keep-derivations" False settings
    go state path
      | Set.member path (liveSet state) = pure (state, True)
      | Set.member path (deadSet state) = pure (state, False)
      | Set.member path roots = pure (state { liveSet = Set.insert path (liveSet state) }, True)
      | otherwise = do
          valid <- isValidPath store path
          if not valid then pure (state, False) else goIncoming state Set.empty path
    goIncoming state visited path = do
      incoming0 <- queryReferrers store path
      derivers <- if keepOutputs then queryValidDerivers store path else pure []
      outputs <- if keepDerivations && ".drv" `B.isSuffixOf` path
        then do
          candidates <- queryDerivationOutputs store path
          valid <- mapM (isValidPath store) candidates
          actualDerivers <- mapM (queryDeriver store) candidates
          pure [candidate | (candidate, True, deriver) <- zip3 candidates valid actualDerivers, deriver == path]
        else pure []
      walk state (Set.insert path visited) path (filter (/= path) (incoming0 ++ derivers ++ outputs))
    walk state visited _ [] = pure (state { deadSet = Set.union (deadSet state) visited }, False)
    walk state visited path (incoming:rest)
      | Set.member incoming visited = walk state visited path rest
      | otherwise = do
          (next, live) <- go state incoming
          if live
            then pure (next { liveSet = Set.insert path (liveSet next) }, True)
            else walk next visited path rest

data GCLimitReached = GCLimitReached deriving (Show, Typeable)
instance Exception GCLimitReached

collectPaths :: Settings -> [ByteString] -> Word64 -> Store -> ByteString -> IO ([ByteString], Word64)
collectPaths settings roots maximumFreed store requester = do
  let rootSet = Set.fromList roots
  paths <- queryAllValidPaths store
  freed <- newIORef 0
  deleted <- newIORef []
  handle (\GCLimitReached -> collectResult freed deleted) $ do
    forM_ paths $ \path -> do
      (_, live) <- canReachRoot settings rootSet store (Reachability Set.empty Set.empty) path
      unless live $ deleteRecursive settings rootSet maximumFreed freed deleted store requester path
    collectResult freed deleted

collectResult :: IORef Word64 -> IORef [ByteString] -> IO ([ByteString], Word64)
collectResult freed deleted = do
  result <- reverse <$> readIORef deleted
  amount <- readIORef freed
  pure (result, amount)

deleteSpecificPaths :: Settings -> [ByteString] -> [ByteString] -> Word64 -> Store -> ByteString -> IO ([ByteString], Word64)
deleteSpecificPaths settings roots paths maximumFreed store requester = do
  let rootSet = Set.fromList roots
  mapM_ (assertStorePath store) paths
  freed <- newIORef 0
  deleted <- newIORef []
  forM_ paths $ \path -> do
    (_, live) <- canReachRoot settings rootSet store (Reachability Set.empty Set.empty) path
    when live $ throwIO (storeError ("cannot delete path `" ++ C.unpack path ++ "' since it is still alive"))
    deleteRecursive settings rootSet maximumFreed freed deleted store requester path
  collectResult freed deleted

deleteRecursive :: Settings -> Set.Set ByteString -> Word64 -> IORef Word64
  -> IORef [ByteString] -> Store -> ByteString -> ByteString -> IO ()
deleteRecursive settings roots maximumFreed freed deleted store requester path = do
  already <- elem path <$> readIORef deleted
  unless already $ do
    valid <- isValidPath store path
    when valid $ do
      (_, live) <- canReachRoot settings roots store (Reachability Set.empty Set.empty) path
      unless live $ do
        referrers <- queryReferrers store path
        forM_ (filter (/= path) referrers) $ \referrer ->
          deleteRecursive settings roots maximumFreed freed deleted store requester referrer
        -- A root may have been registered by another thread of this process
        -- since the live set was computed (DECISIONS.md point 3).  Re-read the
        -- other connections' shared STM announcements before each deletion and
        -- keep a newly rooted path.  The requester's own announcements are
        -- omitted, exactly as withOtherTemporaryRoots omits its temporary-root
        -- file, so a client can still collect its own dead items.
        announced <- Set.fromList <$> announcedRoots (gcPathOf store) requester
        rooted <- if Set.member path announced
          then isValidPath store path
          else pure False
        unless rooted $ do
          info <- queryPathInfo store path
          -- C++ invalidates and schedules deletion without checking maxFreed.
          invalidatePathChecked store path
          modifyIORef' deleted (path:)
          modifyIORef' freed (+ infoNarSize info)
          deleteTree path
          amount' <- readIORef freed
          when (amount' > maximumFreed) $ throwIO GCLimitReached

gcPathOf :: Store -> ByteString
gcPathOf store = storeGcLockPathOf (storeDirectory store) (storeStateDirectory store)

invalidatePath :: Store -> ByteString -> IO ()
invalidatePath store = withTransaction (database store) . invalidatePathSQL store

invalidatePathSQL :: Store -> ByteString -> IO ()
invalidatePathSQL store path = do
  execute (database store) "delete from Refs where referrer in (select id from ValidPaths where path = ?);" [Bytes path]
  execute (database store) "delete from ValidPaths where path = ?;" [Bytes path]

invalidatePathChecked :: Store -> ByteString -> IO ()
invalidatePathChecked store path = withTransaction (database store) $ do
  valid <- isValidPath store path
  when valid $ do
    referrers <- filter (/= path) <$> queryReferrers store path
    unless (null referrers) $ throwIO (storeError ("cannot delete path `" ++ C.unpack path ++ "' because it is in use by " ++ C.unpack (C.intercalate ", " referrers)))
    invalidatePathSQL store path

data VerifyState = VerifyState
  { verifyDone :: !(Set.Set ByteString)
  , verifyValid :: !(Set.Set ByteString)
  , verifyErrors :: !Bool
  }

verifyStorePaths :: Bool -> Bool -> (ByteString -> IO Bool) -> Store -> [ByteString] -> IO Bool
verifyStorePaths checkContents repair repairPath store paths = do
  state <- withGCLock (rootLockPath store) $ foldM verifyExistence (VerifyState Set.empty Set.empty False) paths
  contentErrors <- if checkContents
    then or <$> mapM verifyContents (Set.toAscList (verifyValid state))
    else pure False
  pure (verifyErrors state || contentErrors)
  where
    rootLockPath store' = case storeStateDirectory store' of
      Just state -> state <> "/gc.lock"
      Nothing -> storeDirectory store' <> "/.gc.lock"

    verifyExistence state path
      | Set.member path (verifyDone state) = pure state
      | otherwise = do
          exists <- pathExists path
          if exists
            then pure state { verifyDone = Set.insert path (verifyDone state)
                            , verifyValid = Set.insert path (verifyValid state) }
            else do
              referrers <- filter (/= path) <$> queryReferrers store path
              next <- foldM verifyExistence
                state { verifyDone = Set.insert path (verifyDone state) } referrers
              let hasValidReferrers = any (`Set.member` verifyValid next) referrers
              if not hasValidReferrers
                then invalidatePath store path >> pure next
                else if repair
                  then do
                    repaired <- tryRepair path
                    if repaired
                      then pure next { verifyValid = Set.insert path (verifyValid next) }
                      else pure next { verifyErrors = True }
                  else pure next { verifyErrors = True }

    pathExists path = do
      result <- try (Files.getSymbolicLinkStatus path)
      case result of
        Right _ -> pure True
        Left error' | isDoesNotExistError error' -> pure False
                    | otherwise -> throwIO (error' :: IOException)

    verifyContents path = do
      registered <- isValidPath store path
      if not registered then pure False else do
        info <- queryPathInfo store path
        actualHash <- hashNar path
        actualSize <- fromIntegral . B.length <$> dumpNar path
        if hashDigest actualHash /= infoHash info
          then if repair then not <$> tryRepair path else pure True
          else do
            when (infoNarSize info == 0) $
              execute (database store) "update ValidPaths set narSize = ? where path = ?;"
                [Integer (fromIntegral actualSize), Bytes path]
            pure False

    tryRepair path = do
      result <- try (repairPath path)
      case result of
        Left (_ :: SomeException) -> pure False
        Right False -> pure False
        Right True -> isValidPath store path
