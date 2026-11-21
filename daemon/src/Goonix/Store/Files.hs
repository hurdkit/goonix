{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- Store filesystem operations use raw bytes, not locale-decoded Strings.
module Goonix.Store.Files
  ( restoreNar
  , canonicaliseTree
  , withPathLock
  , withGCLock
  , withGCReadLock
  , withFileLock
  , tryFileLock
  , LockMode (..)
  , lockTableSize
  , withTempRootFile
  , readTemporaryRootFile
  , withTemporaryRoots
  , withOtherTemporaryRoots
  , readLock
  , appendTempRoot
  , announceRoot
  , announcedRoots
  , withdrawRoots
  , storeGcLockPathOf
  , withOwnCollector
  , withCollectorGCLock
  , deduplicateTree
  , makeSymlinkAtomic
  , mkdirParents
  , deleteTree
  , directoryEntries
  , catchMissing
  , withWritableStore
  , writeBytes
  ) where

import Control.Exception (IOException, bracket, bracket_, finally, mask, onException, throwIO, try, uninterruptibleMask_)
import Control.Concurrent (ThreadId, myThreadId, threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar_, modifyMVar, withMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, throwSTM, writeTVar)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Control.Monad (foldM, forM_, unless, when)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.C.Error (Errno (..), eAGAIN, eACCES, eNOENT, getErrno)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CUInt (..))
import Data.Word (Word64)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Data.Bits ((.&.), (.|.))
import Goonix.Store.Nar (Nar (..), hashNar)
import Goonix.Store.Base32 (encodeBase32)
import Goonix.Store.Hash (hashDigest)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Directory.ByteString as Dir
import qualified System.Posix.Files.ByteString as Files
import System.IO.Error (isDoesNotExistError)
import System.Posix.IO.ByteString (closeFd, openFd, OpenMode (WriteOnly), OpenFileFlags (..), defaultFileFlags, fdWrite)
import System.Posix.Types (Fd (..), FileMode)

foreign import ccall unsafe "goonix_restore_node"
  c_restore_node :: CString -> CInt -> CInt -> Ptr () -> Word64 -> IO CInt
foreign import ccall unsafe "goonix_canonicalize" c_canonicalize :: CString -> IO CInt
foreign import ccall safe "goonix_lock_exclusive" c_lock_exclusive :: CString -> IO CInt
foreign import ccall unsafe "goonix_unlock_delete" c_unlock_delete :: CInt -> CString -> IO CInt
foreign import ccall unsafe "goonix_make_symlink" c_make_symlink :: CString -> CString -> IO CInt
foreign import ccall unsafe "goonix_rename" c_rename :: CString -> CString -> IO CInt
foreign import ccall unsafe "goonix_mkdir_parents" c_mkdir_parents :: CString -> CUInt -> IO CInt
foreign import ccall unsafe "goonix_open_lock" c_open_lock :: CString -> CInt -> IO CInt
foreign import ccall unsafe "goonix_lock_stale" c_lock_stale :: CInt -> IO CInt
foreign import ccall safe "goonix_lock_shared" c_lock_shared :: CString -> CInt -> IO CInt
foreign import ccall safe "goonix_lock_upgrade" c_lock_upgrade :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "goonix_lock_nonblocking" c_lock_nonblocking :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "goonix_write_at_end" c_write_at_end :: CInt -> Ptr () -> Word64 -> IO CInt
foreign import ccall unsafe "goonix_dedup_link" c_dedup_link :: CString -> CString -> CString -> IO CInt

restoreNar :: RawFilePath -> Nar -> IO ()
restoreNar path = restore path
  where
    restore p (Regular executable contents) = withCStringBytes p $ \p' ->
      B.useAsCStringLen contents $ \(bytes, len) -> checkIO "cannot restore regular file" $
        c_restore_node p' 0 (if executable then 1 else 0) (castBytes bytes) (fromIntegral len)
    restore p (Symlink target) = withCStringBytes p $ \p' ->
      withCStringBytes target $ \target' -> checkIO "cannot restore symlink" $
        c_restore_node p' 1 0 (castBytes target') (fromIntegral (B.length target))
    restore p (Directory entries) = do
      withCStringBytes p $ \p' -> checkIO "cannot restore directory" $ c_restore_node p' 2 0 nullPtr 0
      forM_ entries $ \(name, child) -> restore (p <> "/" <> name) child

-- Store-directory mode is shared mutable state. Only the short bookkeeping
-- sections are serialized; builders and hashers run concurrently. The final
-- holder restores the mode observed by the first holder.
withWritableStore :: RawFilePath -> IO a -> IO a
withWritableStore = withWritableDirectory

data DirectoryMode = DirectoryBusy | DirectoryWritable !FileMode !Int

{-# NOINLINE writableDirectories #-}
writableDirectories :: TVar (Map.Map RawFilePath DirectoryMode)
writableDirectories = unsafePerformIO (newTVarIO Map.empty)

-- A store path lock creates and removes a sibling .lock file. The daemon may
-- own the store directory while its normal mode denies writes. Save the mode
-- once, keep it writable through the final lock-file unlink, and restore it
-- after the last holder; builders and hashers themselves are not serialized.
withWritableDirectory :: RawFilePath -> IO a -> IO a
withWritableDirectory path action = bracket_ acquire release action
  where
    acquire = mask $ \restore -> do
      first <- atomically $ do
        current <- readTVar writableDirectories
        case Map.lookup path current of
          Nothing -> writeTVar writableDirectories (Map.insert path DirectoryBusy current) >> pure True
          Just (DirectoryWritable original count) -> do
            writeTVar writableDirectories (Map.insert path (DirectoryWritable original (count + 1)) current)
            pure False
          Just DirectoryBusy -> retry
      when first $ do
        original <- (do
          status <- Files.getSymbolicLinkStatus path
          let original = Files.fileMode status
          Files.setFileMode path (original .|. 0o700)
          pure original) `onException` atomically (modifyTVar' writableDirectories (Map.delete path))
        atomically $ modifyTVar' writableDirectories (Map.insert path (DirectoryWritable original 1))
        restore (pure ())
    release = uninterruptibleMask_ $ do
      final <- atomically $ do
        current <- readTVar writableDirectories
        case Map.lookup path current of
          Just (DirectoryWritable original count) | count > 1 -> do
            writeTVar writableDirectories (Map.insert path (DirectoryWritable original (count - 1)) current)
            pure Nothing
          Just (DirectoryWritable original _) -> do
            writeTVar writableDirectories (Map.insert path DirectoryBusy current)
            pure (Just original)
          _ -> throwSTM (userError "store directory mode released without a holder")
      forM_ final $ \original ->
        Files.setFileMode path original `finally` atomically (modifyTVar' writableDirectories (Map.delete path))

writeBytes :: RawFilePath -> ByteString -> IO ()
writeBytes path bytes = bracket (openFd path WriteOnly defaultFileFlags { System.Posix.IO.ByteString.creat = Just 0o666 }) closeFd $ \fd -> do
  let writeAll rest
        | B.null rest = pure ()
        | otherwise = do
            written <- fdWrite fd rest
            when (written == 0) (ioError (userError "cannot write file"))
            writeAll (B.drop (fromIntegral written) rest)
  writeAll bytes

canonicaliseTree :: RawFilePath -> IO ()
canonicaliseTree path = do
  status <- Files.getSymbolicLinkStatus path
  withCStringBytes path (checkIO "cannot canonicalise store item" . c_canonicalize)
  when (Files.isDirectory status) $ do
    entries <- directoryEntries path
    forM_ entries $ \entry -> canonicaliseTree (path <> "/" <> entry)

withPathLock :: RawFilePath -> IO a -> IO a
withPathLock path action = withWritableDirectory (parent path) $
  withFileLock (path <> ".lock") Exclusive True action

withGCLock :: RawFilePath -> IO a -> IO a
withGCLock = gcLock Exclusive

withGCReadLock :: RawFilePath -> IO a -> IO a
withGCReadLock = gcLock Shared

gcLock :: LockMode -> RawFilePath -> IO a -> IO a
gcLock mode path action = do
  mkdirParents (parent path)
  withFileLock path mode False action

-- POSIX locks belong to the process: they exclude nothing between threads,
-- and closing any descriptor of a file drops every process lock on it. Keep
-- one descriptor per lock path and close it only when the last holder leaves.
--
-- A path is absent, Busy (one thread is opening/locking or closing it), or
-- Held. Everybody else waits on this one table. Shared and exclusive holders
-- never coexist, so the kernel lock mode is never changed and needs no
-- downgrade. Re-entering an exclusive lock on one thread is refused.
data LockMode = Shared | Exclusive deriving (Eq, Show)
data LockSlot
  = LockBusy
  | LockHeld !CInt !LockMode !Int !(Maybe ThreadId)

{-# NOINLINE fileLocks #-}
fileLocks :: TVar (Map.Map RawFilePath LockSlot)
fileLocks = unsafePerformIO (newTVarIO Map.empty)

lockTableSize :: IO Int
lockTableSize = Map.size <$> readTVarIO fileLocks

withFileLock :: RawFilePath -> LockMode -> Bool -> IO a -> IO a
withFileLock path mode deleteOnRelease =
  bracket_ (acquireFileLock path mode) (releaseFileLock path deleteOnRelease)

-- Nonblocking acquisition for identities and other resources for which a
-- caller must try the next candidate instead of waiting.  The returned
-- release action keeps the table entry and descriptor until called.
tryFileLock :: RawFilePath -> IO (Maybe (IO ()))
tryFileLock path = mask $ \_restore -> do
  available <- atomically $ do
    table <- readTVar fileLocks
    case Map.lookup path table of
      Nothing -> writeTVar fileLocks (Map.insert path LockBusy table) >> pure True
      _ -> pure False
  if not available then pure Nothing else do
    acquired <- (do
      fd <- withCStringBytes path (\p -> c_open_lock p 1) `onException`
        atomically (modifyTVar' fileLocks (Map.delete path))
      when (fd < 0) (errnoIO "cannot open file lock")
      result <- c_lock_nonblocking fd 1
      if result == 0 then pure (Just fd) else do
        errno <- getErrno
        closeFd (Fd fd)
        if errno == eAGAIN || errno == eACCES then pure Nothing
          else errnoIO "cannot acquire file lock") `onException`
        atomically (modifyTVar' fileLocks (Map.delete path))
    case acquired of
      Nothing -> do
        atomically $ modifyTVar' fileLocks (Map.delete path)
        pure Nothing
      Just fd -> do
        self <- myThreadId
        atomically $ modifyTVar' fileLocks (Map.insert path (LockHeld fd Exclusive 1 (Just self)))
        pure (Just (releaseFileLock path False))


acquireFileLock :: RawFilePath -> LockMode -> IO ()
acquireFileLock path mode = mask $ \restore -> do
  self <- myThreadId
  -- A committed acquisition is followed by the cleanup handler while masked.
  first <- atomically $ do
    table <- readTVar fileLocks
    case Map.lookup path table of
      Nothing -> writeTVar fileLocks (Map.insert path LockBusy table) >> pure True
      Just (LockHeld fd Shared holders _) | mode == Shared -> do
        writeTVar fileLocks (Map.insert path (LockHeld fd Shared (holders + 1) Nothing) table)
        pure False
      Just (LockHeld _ Exclusive _ (Just owner)) | owner == self ->
        throwSTM (userError ("deadlock: this thread already holds the lock on " ++ show path))
      Just _ -> retry
  when first $ do
    fd <- acquireExternal restore path mode `onException`
      atomically (modifyTVar' fileLocks (Map.delete path))
    atomically $ modifyTVar' fileLocks $
      Map.insert path (LockHeld fd mode 1 (if mode == Exclusive then Just self else Nothing))

-- Only the wait for another process is interruptible. Its descriptor and the
-- Busy slot are removed if it is cancelled.
acquireExternal :: (IO () -> IO ()) -> RawFilePath -> LockMode -> IO CInt
acquireExternal restore path mode = do
  fd <- withCStringBytes path (\p -> c_open_lock p 1)
  when (fd < 0) (errnoIO "cannot open file lock")
  restore (waitLock fd 1000) `onException` closeFd (Fd fd)
  stale <- c_lock_stale fd
  case stale of
    0 -> pure fd
    1 -> closeFd (Fd fd) >> acquireExternal restore path mode
    _ -> closeFd (Fd fd) >> errnoIO "cannot examine file lock"
  where
    waitLock fd delay = do
      result <- c_lock_nonblocking fd (if mode == Exclusive then 1 else 0)
      when (result /= 0) $ do
        errno <- getErrno
        if errno == eAGAIN || errno == eACCES
          then threadDelay delay >> waitLock fd (min 50000 (delay * 2))
          else errnoIO "cannot acquire file lock"

releaseFileLock :: RawFilePath -> Bool -> IO ()
releaseFileLock path deleteOnRelease = uninterruptibleMask_ $ do
  final <- atomically $ do
    table <- readTVar fileLocks
    case Map.lookup path table of
      Just (LockHeld fd mode holders owner)
        | holders > 1 -> do
            writeTVar fileLocks (Map.insert path (LockHeld fd mode (holders - 1) owner) table)
            pure Nothing
        | otherwise -> writeTVar fileLocks (Map.insert path LockBusy table) >> pure (Just fd)
      _ -> throwSTM (userError ("file lock released without a holder: " ++ show path))
  forM_ final $ \fd ->
    closeLock fd `finally` atomically (modifyTVar' fileLocks (Map.delete path))
  where
    closeLock fd = do
      result <- if deleteOnRelease
        then withCStringBytes path (c_unlock_delete fd)
        else closeFd (Fd fd) >> pure 0
      when (result < 0) (errnoIO "cannot release file lock")

withTempRootFile :: RawFilePath -> RawFilePath -> (Fd -> IO a) -> IO a
withTempRootFile path gcPath action = do
  mkdirParents (parent path)
  bracket acquire release (action . rootDescriptor)
  where
    -- A new client skips the shared GC lock only while THIS process's own
    -- collector holds it (DECISIONS.md point 3): that collector reads the shared
    -- STM announcements, so a root registered during the collection is kept.
    -- Against another process's collector the shared lock is still taken, so a
    -- new client waits for that collection — the shared lock at creation is what
    -- guarantees no temporary-root file appears after the other collector has
    -- enumerated the directory.  The temporary-root file's own exclusive flock
    -- still excludes other processes.
    acquire = withMVar tempRootLock $ \() -> modifyMVar tempRoot $ \roots ->
      case Map.lookup path roots of
        Just root -> pure (Map.insert path root { rootUsers = rootUsers root + 1 } roots, root)
        Nothing -> do
          own <- ownCollectorHolds gcPath
          root <- if own then testDelay >> openRoot else withGCReadLock gcPath openRoot
          pure (Map.insert path root roots, root)
    -- Test-only: widen the flag-check -> file-creation window of a client that
    -- skips the shared GC lock (collector-release-race.sh).  No-op unless the
    -- env var is set.  With the pre-fix release (flag and lock released WITHOUT
    -- tempRootLock) this delay lets the collector release and another process's
    -- collector enumerate before this client's file exists.  With the fix the
    -- collector's release waits for tempRootLock, which this client holds across
    -- the delay and openRoot, so the file exists before the GC lock is freed.
    testDelay = do
      delay <- lookupEnv "GOONIX_TEST_TEMPROOT_CREATE_DELAY_US"
      forM_ delay $ \value -> case reads value of
        [(micros, "")] | micros > 0 -> threadDelay micros
        _ -> pure ()
    openRoot = do
      fd <- withCStringBytes path c_lock_exclusive
      if fd >= 0 then do
        let descriptor = Fd fd
        readLock descriptor
        pure (Root descriptor [] 1 gcPath)
      else do
        Errno errno <- getErrno
        if Errno errno == eAGAIN then Files.removeLink path `catchMissing` pure () >> openRoot
          else errnoIO "cannot acquire temporary roots lock"
    release _root = withMVar tempRootLock $ \() -> modifyMVar_ tempRoot $ \roots ->
      case Map.lookup path roots of
        Nothing -> throwIO (userError "temporary root file released without an owner")
        Just current
          | rootUsers current > 1 -> pure (Map.insert path current { rootUsers = rootUsers current - 1 } roots)
          | otherwise -> do
              closeFd (rootDescriptor current)
              Files.removeLink path `catchMissing` pure ()
              withdrawRoots (rootGcPath current) path
              pure (Map.delete path roots)

data Root = Root
  { rootDescriptor :: !Fd
  , rootPaths :: ![ByteString]
  , rootUsers :: !Int
  , rootGcPath :: !RawFilePath
  }

{-# NOINLINE tempRoot #-}
tempRoot :: MVar (Map.Map RawFilePath Root)
tempRoot = unsafePerformIO (newMVar Map.empty)

{-# NOINLINE tempRootLock #-}
tempRootLock :: MVar ()
tempRootLock = unsafePerformIO (newMVar ())

-- A running collector learns of new roots from the other threads of this
-- process through shared STM state (DECISIONS.md point 3, after parity).
-- Every temporary root appended by a build or upload, and every indirect root,
-- is announced here.  The table is keyed by the store's GC-lock path, then by
-- the announcing connection's temporary-root file path, so two daemons on one
-- store keep separate tables (they exclude each other through the lock files)
-- and the collector can omit the requesting connection's own roots exactly as
-- withOtherTemporaryRoots omits its temporary-root file.  The collector re-reads
-- the other connections' announcements before each deletion and treats them as
-- roots, so an item rooted while a collection runs is kept.  A connection's
-- announcements are dropped when its temporary-root file is released, so a
-- stale announcement cannot keep a dead item alive.  This is what lets builds
-- and new clients run during a collection instead of waiting on the GC lock;
-- the lock files still exclude other daemon processes.
{-# NOINLINE rootAnnouncements #-}
rootAnnouncements :: TVar (Map.Map RawFilePath (Map.Map RawFilePath (Set.Set ByteString)))
rootAnnouncements = unsafePerformIO (newTVarIO Map.empty)

-- | Announce a newly registered root for the store named by its GC-lock path,
-- attributed to the announcing connection's temporary-root file.
announceRoot :: RawFilePath -> RawFilePath -> ByteString -> IO ()
announceRoot gcPath owner path = atomically $
  modifyTVar' rootAnnouncements $
    Map.insertWith (Map.unionWith Set.union) gcPath
      (Map.singleton owner (Set.singleton path))

-- | The roots announced for this store by connections other than the requester
-- (identified by its temporary-root file path).  Mirrors withOtherTemporaryRoots.
announcedRoots :: RawFilePath -> RawFilePath -> IO [ByteString]
announcedRoots gcPath requester = do
  table <- readTVarIO rootAnnouncements
  let owners = Map.findWithDefault Map.empty gcPath table
      others = Map.delete requester owners
  pure (Set.toAscList (Set.unions (Map.elems others)))

-- | Drop a connection's announcements when its temporary-root file is released.
withdrawRoots :: RawFilePath -> RawFilePath -> IO ()
withdrawRoots gcPath owner = atomically $
  modifyTVar' rootAnnouncements $
    Map.adjust (Map.delete owner) gcPath

-- | The GC-lock path of a store, the key of its root-announcement table and
-- the file two daemons on one store exclude each other through.
storeGcLockPathOf :: ByteString -> Maybe ByteString -> ByteString
storeGcLockPathOf storeDir stateDir = case stateDir of
  Just state -> state <> "/gc.lock"
  Nothing -> storeDir <> "/.gc.lock"

-- While THIS process's collector holds the GC lock exclusively, a new client of
-- this process may create its temporary-root file without taking the shared GC
-- lock: the collector reads the shared STM announcements, so a root registered
-- during the collection is still kept (DECISIONS.md point 3).  Against another
-- process's collector the shared lock is still required — that collector cannot
-- see our announcements, and the shared lock at creation is what guarantees no
-- temporary-root file appears after it has enumerated the directory.  The flag
-- names the GC-lock paths our own collector currently holds.
{-# NOINLINE ownCollector #-}
ownCollector :: TVar (Set.Set RawFilePath)
ownCollector = unsafePerformIO (newTVarIO Set.empty)

-- | Run an action while recording that this process's collector holds the GC
-- lock on the given path.  Cleared on release, even on exception.
withOwnCollector :: RawFilePath -> IO a -> IO a
withOwnCollector gcPath =
  bracket_ (atomically (modifyTVar' ownCollector (Set.insert gcPath)))
           (atomically (modifyTVar' ownCollector (Set.delete gcPath)))

-- | Does this process's own collector currently hold the GC lock on this path?
ownCollectorHolds :: RawFilePath -> IO Bool
ownCollectorHolds gcPath = Set.member gcPath <$> readTVarIO ownCollector

-- | Run a collection under the exclusive GC lock, with the own-collector flag
-- set.  Acquire-and-flag-set is ONE step under tempRootLock; the collection body
-- runs without tempRootLock; release of BOTH the flag and the lock is under
-- tempRootLock.
--
-- The acquire ordering matters as much as the release.  A new client checks
-- ownCollectorHolds and then creates its temporary-root file (or takes the
-- shared GC lock), all under tempRootLock (withTempRootFile).  If the collector
-- took the exclusive GC lock and only THEN set the flag, a client arriving in
-- between would see the flag unset, take tempRootLock, and block in
-- withGCReadLock on the collector's exclusive lock — while still holding
-- tempRootLock.  The collector's release then waits for tempRootLock: deadlock.
-- Acquiring the lock and setting the flag together under tempRootLock means a
-- client enters either BEFORE (flag unset; it takes the shared lock and lets go
-- of it before the collector can get the exclusive one) or AFTER (flag set; it
-- skips the shared lock).  While the flag is set, new clients skip the GC lock
-- and never block inside tempRootLock, so the collection body's brief
-- tempRootLock uses (withOtherTemporaryRoots, appendTempRoot) are safe.
--
-- The release ordering closes the cross-process gap: a client that saw the flag
-- set holds tempRootLock through openRoot, so it has finished creating its file
-- before this release completes; no other process can take the GC lock and
-- enumerate temproots/ until the file exists.
withCollectorGCLock :: RawFilePath -> IO a -> IO a
withCollectorGCLock gcPath action = do
  mkdirParents (parent gcPath)
  bracket acquireLocked (const releaseLocked) $ \_ -> action
  where
    acquireLocked = withMVar tempRootLock $ \() -> do
      acquireFileLock gcPath Exclusive
      -- Test-only: widen the acquire -> flag-set window so the deadlock ordering
      -- can be stressed (collector-acquire-race.sh).  No-op unless the env var
      -- is set.  The delay is INSIDE tempRootLock, so a new client cannot enter
      -- between the acquire and the flag-set; with the pre-fix acquire (lock
      -- taken, flag set later, both outside tempRootLock) a client could.
      flagDelay <- lookupEnv "GOONIX_TEST_COLLECTOR_FLAG_DELAY_US"
      forM_ flagDelay $ \value -> case reads value of
        [(micros, "")] | micros > 0 -> threadDelay micros
        _ -> pure ()
      atomically (modifyTVar' ownCollector (Set.insert gcPath))
    releaseLocked = withMVar tempRootLock $ \() -> uninterruptibleMask_ $ do
      atomically (modifyTVar' ownCollector (Set.delete gcPath))
      releaseFileLock gcPath False

withTemporaryRoots :: RawFilePath -> ([ByteString] -> IO a) -> IO a
withTemporaryRoots = withTemporaryRootsExcept Nothing

-- C++ GC reopens its process's temporary-root file and can take its write
-- lock.  In this threaded daemon that descriptor belongs to one connection;
-- omit only that requester, not the other clients' live roots.
withOtherTemporaryRoots :: RawFilePath -> Fd -> ([ByteString] -> IO a) -> IO a
withOtherTemporaryRoots directory requester = withTemporaryRootsExcept (Just requester) directory

withTemporaryRootsExcept :: Maybe Fd -> RawFilePath -> ([ByteString] -> IO a) -> IO a
withTemporaryRootsExcept requester directory action = withMVar tempRootLock $ \() -> do
  own <- withMVar tempRoot $ pure . Map.filterWithKey (\path _ -> (directory <> "/") `B.isPrefixOf` path)
  let retained = case requester of
        Nothing -> own
        Just fd -> Map.filter ((/= fd) . rootDescriptor) own
  bracket (readRoots [] own retained) (mapM_ closeFd . snd) (action . fst)
  where
    readRoots locks own retained = do
      entries <- directoryEntries directory
      let external = [file | file <- entries, not (Map.member (directory <> "/" <> file) own)]
      foldM readOne (concatMap rootPaths (Map.elems retained), locks) external
    readOne (roots, locks) file = do
      let path = directory <> "/" <> file
      fd <- withCStringBytes path (\p -> c_lock_shared p 0)
      if fd < 0 then do
        Errno errno <- getErrno
        if Errno errno == eNOENT then pure (roots, locks)
          else ioError (userError "cannot open temporary roots file")
      else do
        result <- c_lock_nonblocking fd 1
        if result == 0 then do
          Files.removeLink path `catchMissing` pure ()
          _ <- fdWrite (Fd fd) "d"
          closeFd (Fd fd)
          pure (roots, locks)
        else do
          readLock (Fd fd)
          temporary <- readTemporaryRootFile (Fd fd)
          pure (roots ++ temporary, Fd fd : locks)

readTemporaryRootFile :: Fd -> IO [ByteString]
readTemporaryRootFile (Fd fd) = filter (not . B.null) . B.split 0 . B.concat . reverse <$> readChunks 0 []
  where
    readChunks offset acc = do
      (buffer, count) <- allocaBytes 65536 $ \buffer -> do
        count <- c_read fd buffer 65536 offset
        pure (buffer, count)
      if count < 0 then errnoIO "cannot read temporary roots file"
        else if count == 0 then pure acc
          else do
            bytes <- B.packCStringLen (castPtr buffer, count)
            readChunks (offset + fromIntegral count) (bytes : acc)

appendTempRoot :: Fd -> RawFilePath -> IO ()
readLock :: Fd -> IO ()
readLock (Fd fd) = checkIO "cannot acquire temporary roots read lock" (c_lock_upgrade fd 0)

appendTempRoot fd path = withMVar tempRootLock $ \() -> do
  found <- modifyMVar tempRoot $ \roots ->
    case [(name, root) | (name, root) <- Map.toList roots, rootDescriptor root == fd] of
      [] -> pure (roots, Nothing)
      (name, root):_ -> pure (Map.insert name root { rootPaths = path : rootPaths root } roots, Just (rootGcPath root, name))
  case found of
    Nothing -> throwIO (userError "cannot append to an unowned temporary roots file")
    Just (gcPath, owner) -> announceRoot gcPath owner path
  checkIO "cannot upgrade temporary roots lock" (c_lock_upgrade (case fd of Fd raw -> raw) 1)
  result <- B.useAsCStringLen (path <> "\0") $ \(bytes, len) -> c_write_at_end (case fd of Fd raw -> raw) (castPtr bytes) (fromIntegral len)
  when (result < 0) (errnoIO "cannot write temporary root")
  checkIO "cannot downgrade temporary roots lock" (c_lock_upgrade (case fd of Fd raw -> raw) 0)

foreign import ccall safe "pread"
  c_read :: CInt -> Ptr () -> Word64 -> Word64 -> IO Int

deduplicateTree :: RawFilePath -> RawFilePath -> IO ()
deduplicateTree store path = do
  unless (store == path) $ do
    mkdirParents (store <> "/.links")
    walk path
  where
    walk p = do
      status <- Files.getSymbolicLinkStatus p
      if Files.isDirectory status
        then directoryEntries p >>= mapM_ (\entry -> walk (p <> "/" <> entry))
        else when (Files.isRegularFile status && Files.fileSize status >= 8192 && Files.fileMode status .&. 0o200 == 0) $ do
          digest <- hashFileNar p
          let linkPath = store <> "/.links/" <> digest
              temporary = store <> "/.tmp-goonix-dedup"
          result <- withCStringBytes p $ \p' -> withCStringBytes linkPath $ \link' -> withCStringBytes temporary $ \temp' -> c_dedup_link p' link' temp'
          when (result < 0) (errnoIO "cannot deduplicate store file")
    hashFileNar p = do
      hash <- hashNar p
      pure (encodeBase32 (hashDigest hash))

makeSymlinkAtomic :: RawFilePath -> RawFilePath -> IO ()
makeSymlinkAtomic target link = do
  mkdirParents (parent link)
  let temporary = link <> ".tmp-goonix"
  Files.removeLink temporary `catchMissing` pure ()
  withCStringBytes target $ \target' -> withCStringBytes temporary $ \temporary' ->
    checkIO "cannot create symbolic link" (c_make_symlink target' temporary')
  withCStringBytes temporary $ \from -> withCStringBytes link $ \to ->
    checkIO "cannot rename symbolic link" (c_rename from to)

mkdirParents :: RawFilePath -> IO ()
mkdirParents path = withCStringBytes path $ \path' -> checkIO "cannot create directories" (c_mkdir_parents path' 0o755)

deleteTree :: RawFilePath -> IO ()
deleteTree path = do
  -- Use lstat, not fileExist: a symlink to another store path is dangling
  -- outside the private sandbox root, but its directory entry still needs
  -- to be removed.
  result <- try (Files.getSymbolicLinkStatus path)
  case result of
    Left error' | isDoesNotExistError error' -> pure ()
                | otherwise -> throwIO (error' :: IOException)
    Right status -> remove status
  where
    remove status
      | Files.isDirectory status = do
          Files.setFileMode path 0o755
          entries <- directoryEntries path
          forM_ entries $ \entry -> deleteTree (path <> "/" <> entry)
          Dir.removeDirectory path
      | otherwise = do
          let directory = parent path
          parentStatus <- Files.getSymbolicLinkStatus directory
          Files.setFileMode directory 0o755
          (unless (Files.isSymbolicLink status) (Files.setFileMode path 0o644) >> Files.removeLink path)
            `finally` Files.setFileMode directory (Files.fileMode parentStatus)

directoryEntries :: RawFilePath -> IO [RawFilePath]
directoryEntries path = bracket (Dir.openDirStream path) Dir.closeDirStream $ \stream -> do
  let loop acc = do
        entry <- Dir.readDirStream stream
        if B.null entry then pure (reverse acc)
          else if entry == "." || entry == ".." then loop acc else loop (entry:acc)
  loop []

parent :: RawFilePath -> RawFilePath
parent path = case B.breakEnd (== 47) path of
  ("", _) -> "."
  (directory, _) -> if directory == "/" then "/" else B.init directory

catchMissing :: IO a -> IO a -> IO a
catchMissing action fallback = do
  result <- try action
  case result of
    Right value -> pure value
    Left error' | isDoesNotExistError error' -> fallback
                | otherwise -> throwIO (error' :: IOException)

withCStringBytes :: RawFilePath -> (CString -> IO a) -> IO a
withCStringBytes = B.useAsCString

castBytes :: Ptr a -> Ptr ()
castBytes = castPtr

checkIO :: String -> IO CInt -> IO ()
checkIO message action = do
  result <- action
  when (result < 0) (errnoIO message)

errnoIO :: String -> IO a
errnoIO message = do
  Errno number <- getErrno
  ioError (userError (message ++ ": errno=" ++ show number))
