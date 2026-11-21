{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
module Goonix.Build.Users
  ( BuildUser (..)
  , UserPool
  , UserLease
  , parsePasswd
  , parseGroup
  , allocateUsers
  , createUserPool
  , acquireUser
  , releaseLease
  , withBuildUser
  , withBuildUserUsing
  , loadUserPool
  , userLease
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (SomeException, bracket, finally, mask, onException, throwIO, try, uninterruptibleMask_)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32)
import Foreign.C.Types (CInt (..))
import Goonix.Store.Files (mkdirParents, tryFileLock)
import Goonix.Store.ReadOnly (storeError)
import System.Posix.Env.ByteString (getEnv)
import System.Posix.Types (CUid (..))
import System.Posix.User (getEffectiveUserID, getRealUserID)

data BuildUser = BuildUser
  { buildUserName :: !B.ByteString
  , buildUserUid :: !Word32
  , buildUserGid :: !Word32
  , buildUserGroups :: ![Word32]
  } deriving (Eq, Show)

-- The lock belongs to the lease, not to a client connection.  It remains held
-- through the builder, output registration, and the final UID cleanup.
data UserLease = UserLease !BuildUser !(IO ())
data UserPool = UserPool !B.ByteString !(TVar [BuildUser])

-- Unrelated system entries are deliberately ignored.  Only the selected build
-- group and its members are part of the daemon's contract.
parsePasswd :: B.ByteString -> Map.Map B.ByteString (Word32, Word32)
parsePasswd = Map.fromList . foldr entry [] . C.lines
  where
    entry line rest = case C.split ':' line of
      (name:_:uid:gid:_) | not (B.null name), Just u <- number uid, Just g <- number gid ->
        (name, (u, g)) : rest
      _ -> rest
    number bytes = case reads (C.unpack bytes) of
      [(n, "")] | n >= 0 && n <= 4294967295 -> Just (fromIntegral n)
      _ -> Nothing

parseGroup :: B.ByteString -> B.ByteString -> Either String (Word32, [B.ByteString])
parseGroup group contents = case filter matches (C.lines contents) of
  [line] -> case C.split ':' line of
    [_, _, gid, members] -> case reads (C.unpack gid) of
      [(n, "")] | n > 0 && n <= 4294967295 ->
        Right (fromIntegral n, filter (not . B.null) (C.split ',' members))
      _ -> Left "invalid build group id"
    _ -> Left "malformed build group entry"
  [] -> Left ("build group not found: " ++ C.unpack group)
  _ -> Left ("duplicate build group entry: " ++ C.unpack group)
  where
    matches line = case C.split ':' line of
      name:_ -> name == group
      _ -> False

allocateUsers :: Word32 -> [B.ByteString] -> Map.Map B.ByteString (Word32, Word32) -> Either String [BuildUser]
allocateUsers groupGid names users = mapM allocate (unique names)
  where
    unique = foldr (\name rest -> name : filter (/= name) rest) []
    allocate name = case Map.lookup name users of
      Just (uid, _) | uid /= 0 -> Right (BuildUser name uid groupGid [])
      _ -> Left ("unknown or unusable build user: " ++ C.unpack name)

supplementaryGroups :: B.ByteString -> B.ByteString -> [Word32]
supplementaryGroups name = foldr group [] . C.lines
  where
    group line result = case C.split ':' line of
      [_group, _, gid, members] | name `elem` C.split ',' members, Just n <- number gid -> n : result
      _ -> result
    number bytes = case reads (C.unpack bytes) of
      [(n, "")] | n >= 0 && n <= 4294967295 -> Just (fromIntegral n)
      _ -> Nothing

loadUserPool :: B.ByteString -> B.ByteString -> IO (Maybe UserPool)
loadUserPool state group
  | B.null group = pure Nothing
  | otherwise = do
      groupFile <- maybe "/etc/group" id <$> getEnv "GUIX_BUILD_GROUP_FILE"
      passwdFile <- maybe "/etc/passwd" id <$> getEnv "GUIX_BUILD_PASSWD_FILE"
      groupBytes <- B.readFile (C.unpack groupFile)
      (groupGid, names) <- either (throwIO . storeError) pure (parseGroup group groupBytes)
      users <- parsePasswd <$> B.readFile (C.unpack passwdFile)
      selected <- either (throwIO . storeError) pure (allocateUsers groupGid names users)
      if null selected
        then throwIO (storeError ("the build users group " <> C.unpack group <> " has no members"))
        else do
          let withGroups = map (addGroups users groupBytes) selected
          Just <$> createUserPool (state <> "/userpool") withGroups
  where
    addGroups users groupBytes user =
      let primary = maybe [] (pure . snd) (Map.lookup (buildUserName user) users)
          groups = primary ++ supplementaryGroups (buildUserName user) groupBytes
      in user { buildUserGroups = foldr (\gid rest -> gid : filter (/= gid) rest) [] groups }

createUserPool :: B.ByteString -> [BuildUser] -> IO UserPool
createUserPool directory users = UserPool directory <$> newTVarIO users

acquireUser :: UserPool -> IO UserLease
acquireUser pool = mask $ \_ -> acquireSkipping Set.empty
  where
    acquireSkipping skipped = do
      uid <- fromIntegral <$> getRealUserID
      euid <- fromIntegral <$> getEffectiveUserID
      candidate <- atomically $ do
        users <- readTVar available
        case users of
          [] -> pure Nothing
          user:rest -> writeTVar available rest >> pure (Just user)
      case candidate of
        Nothing -> throwIO (storeError "all build users are currently in use; add more users to the build group")
        Just user
          | buildUserUid user == uid || buildUserUid user == euid || buildUserUid user == 0 ->
              releaseUser user >> throwIO (storeError "the build user must differ from the daemon user")
          | Set.member (buildUserUid user) skipped ->
              releaseUser user >> throwIO (storeError "all build users are currently in use; add more users to the build group")
          | otherwise -> do
              mkdirParents directory
              let lockPath = directory <> "/" <> C.pack (show (buildUserUid user))
              locked <- tryFileLock lockPath `onException` releaseUser user
              case locked of
                Just release -> pure (UserLease user release)
                Nothing -> do
                  releaseUser user
                  acquireSkipping (Set.insert (buildUserUid user) skipped)
    UserPool directory available = pool
    releaseUser user = atomically $ do
      users <- readTVar available
      writeTVar available (users ++ [user])

releaseLease :: UserPool -> UserLease -> IO ()
releaseLease (UserPool _ available) (UserLease user release) = release `finally` do
  atomically $ do
    users <- readTVar available
    writeTVar available (users ++ [user])

userLease :: UserLease -> BuildUser
userLease (UserLease user _) = user

foreign import ccall safe "goonix_kill_user" c_kill_user :: CUid -> IO CInt

killUser :: BuildUser -> IO ()
killUser user = do
  result <- c_kill_user (fromIntegral (buildUserUid user))
  if result == 0
    then pure ()
    else throwIO (storeError ("cannot clean up processes for build user " <> C.unpack (buildUserName user)))

withBuildUser :: forall a. UserPool -> (BuildUser -> IO a) -> IO a
withBuildUser = withBuildUserUsing killUser

-- Injectable only for the bounded unit tests of the exception boundary. The
-- daemon uses the real UID sweep above; the root VM checks its OS effects.
withBuildUserUsing :: forall a. (BuildUser -> IO ()) -> UserPool -> (BuildUser -> IO a) -> IO a
withBuildUserUsing sweep pool action = bracket (acquireUser pool) (releaseLease pool) $ \lease ->
  mask $ \restore -> do
    let user = userLease lease
    sweep user
    result <- try (restore (action user)) :: IO (Either SomeException a)
    cleanup <- try (uninterruptibleMask_ (sweep user)) :: IO (Either SomeException ())
    case (result, cleanup) of
      (Left exception, _) -> throwIO exception
      (Right _, Left exception) -> throwIO exception
      (Right value, Right ()) -> pure value
