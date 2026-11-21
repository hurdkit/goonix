{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Goonix.Store.ReadOnly
  ( Store (..)
  , ValidPathInfo (..)
  , StoreError (..)
  , openStore
  , closeStore
  , findRoots
  , isValidPath
  , queryValidPaths
  , queryAllValidPaths
  , queryPathInfo
  , queryPathHash
  , queryReferences
  , queryReferrers
  , queryDeriver
  , queryValidDerivers
  , queryDerivationOutputs
  , queryDerivationOutputNames
  , queryPathFromHashPart
  , queryFailedPaths
  , hasPathFailed
  , storePath
  , assertStorePath
  , storeError
  ) where

import Control.Exception (Exception, bracketOnError, throwIO)
import Control.Monad (foldM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.List (sort)
import System.FilePath (takeDirectory)
import System.IO.Error (catchIOError)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Directory.ByteString as Dir
import qualified System.Posix.Files.ByteString as Files
import Data.Word (Word32, Word64)
import qualified Goonix.Config as Config
import Goonix.Store.Files (mkdirParents)
import Goonix.Store.Base32 (decodeBase16)
import Goonix.Store.Database
import Goonix.Store.Hash

data Store = Store
  { storeDirectory :: !ByteString
  , storeDatabasePath :: !FilePath
  , storeStateDirectory :: !(Maybe ByteString)
  , database :: !Database
  , statementValidPath :: !Statement
  , statementAllPaths :: !Statement
  , statementReferences :: !Statement
  , statementReferrers :: !Statement
  , statementValidDerivers :: !Statement
  , statementDerivationOutputs :: !Statement
  , statementHashPart :: !Statement
  , statementFailedPaths :: !Statement
  }

data ValidPathInfo = ValidPathInfo
  { infoId :: !Int64
  , infoPath :: !ByteString
  , infoHash :: !ByteString
  , infoDeriver :: !ByteString
  , infoReferences :: ![ByteString]
  , infoRegistrationTime :: !Word64
  , infoNarSize :: !Word64
  } deriving (Eq, Show)

data StoreError = StoreError
  { storeErrorMessage :: !ByteString
  , storeErrorStatus :: !Word32
  } deriving (Eq, Show)
instance Exception StoreError

storeError :: String -> StoreError
storeError message = StoreError (C.pack message) 1

assertStorePath :: Store -> ByteString -> IO ByteString
assertStorePath store path = either (throwIO . storeError) pure (storePath store path)

openStore :: ByteString -> FilePath -> IO Store
openStore directory databasePath = withSchemaLock $ do
  mkdirParents (C.pack (takeDirectory databasePath))
  bracketOnError (openReadWrite databasePath) closeDatabase $ \db -> do
    initializeSchemaSql db (C.pack Config.schemaSql)
    let prepare' = prepare db
    Store directory databasePath Nothing db
      <$> prepare' "select id, hash, registrationTime, deriver, narSize from ValidPaths where path = ?;"
      <*> prepare' "select path from ValidPaths"
      <*> prepare' "select path from Refs join ValidPaths on reference = id where referrer = ?;"
      <*> prepare' "select path from Refs join ValidPaths on referrer = id where reference = (select id from ValidPaths where path = ?);"
      <*> prepare' "select v.path from DerivationOutputs d join ValidPaths v on d.drv = v.id where d.path = ?;"
      <*> prepare' "select id, path from DerivationOutputs where drv = ?;"
      <*> prepare' "select path from ValidPaths where path >= ? limit 1;"
      <*> prepare' "select path from FailedPaths;"

closeStore :: Store -> IO ()
closeStore store = do
  mapM_ closeStatement
    [ statementValidPath store, statementAllPaths store, statementReferences store
    , statementReferrers store, statementValidDerivers store, statementDerivationOutputs store
    , statementHashPart store, statementFailedPaths store ]
  closeDatabase (database store)

findRoots :: Store -> IO [(ByteString, ByteString)]
findRoots store = case storeStateDirectory store of
  Nothing -> pure []
  Just state -> do
    roots <- foldM (scanRootDirectory store) Map.empty
      [state <> "/gcroots", state <> "/manifests", state <> "/profiles"]
    pure (Map.toAscList roots)

scanRootDirectory :: Store -> Map.Map ByteString ByteString -> RawFilePath
  -> IO (Map.Map ByteString ByteString)
scanRootDirectory store initial root = catchIOError (walk initial root) (const (pure initial))
  where
    walk roots path = do
      status <- Files.getSymbolicLinkStatus path
      if Files.isDirectory status
        then do
          entries <- Dir.openDirStream path
          children <- readEntries entries []
          Dir.closeDirStream entries
          foldM walk roots [path <> "/" <> child | child <- children, child /= "." && child /= ".."]
        else if Files.isSymbolicLink status
          then do
            target <- Files.readSymbolicLink path
            if B.isPrefixOf (storeDirectory store <> "/") target
              then addRoot roots path target
              else do
                let indirect = if B.isPrefixOf "/" target then target else takeDirectoryBytes path <> "/" <> target
                exists <- Files.fileExist indirect
                if not exists then pure roots else do
                  targetStatus <- Files.getSymbolicLinkStatus indirect
                  if Files.isSymbolicLink targetStatus
                    then Files.readSymbolicLink indirect >>= addRoot roots indirect
                    else pure roots
          else if Files.isRegularFile status
            then addRoot roots path (storeDirectory store <> "/" <> snd (C.breakEnd (== '/') path))
            else pure roots
    addRoot roots link target = do
      valid <- isValidPath store target
      pure (if valid then Map.insert link target roots else roots)
    readEntries entries acc = do
      entry <- Dir.readDirStream entries
      if B.null entry then pure (reverse acc) else readEntries entries (entry:acc)

takeDirectoryBytes :: RawFilePath -> RawFilePath
takeDirectoryBytes path = case B.reverse (B.dropWhile (/= 47) (B.reverse path)) of
  "" -> "."
  directory -> directory

storePath :: Store -> ByteString -> Either String ByteString
storePath store path
  | B.isPrefixOf (storeDirectory store <> "/") path
      && not (B.isInfixOf "/" (B.drop (B.length (storeDirectory store) + 1) path))
      && B.length path > B.length (storeDirectory store) + 1 = Right path
  | otherwise = Left ("path `" ++ C.unpack path ++ "' is not in the store")

queryRowsStatement :: Store -> Statement -> [Value] -> IO [[ByteString]]
queryRowsStatement store statement values = map (map bytes) <$> query (database store) statement values
  where
    bytes (Bytes value) = value
    bytes Null = B.empty
    bytes (Integer value) = error ("integer SQLite value where bytes expected: " ++ show value)

queryOne :: Store -> Statement -> [Value] -> IO (Maybe [Value])
queryOne store statement values = query (database store) statement values >>= \case
  [] -> pure Nothing
  [row] -> pure (Just row)
  _ -> throwIO (storeError "SQLite query returned multiple rows")

pathId :: Store -> ByteString -> IO Int64
pathId store path = queryOne store (statementValidPath store)
  [Bytes path] >>= \case
    Just (Integer identifier:_) -> pure identifier
    _ -> throwIO (storeError ("path `" ++ C.unpack path ++ "' is not valid"))

isValidPath :: Store -> ByteString -> IO Bool
isValidPath store path = case storePath store path of
  Left _ -> pure False
  Right _ -> maybe False (const True) <$> queryOne store (statementValidPath store)
    [Bytes path]

queryValidPaths :: Store -> [ByteString] -> IO [ByteString]
queryValidPaths store paths = do
  valid <- mapM (isValidPath store) paths
  pure (sort [path | (path, True) <- zip paths valid])

queryAllValidPaths :: Store -> IO [ByteString]
queryAllValidPaths store = sort . concat <$> queryRowsStatement store (statementAllPaths store) []

queryPathInfo :: Store -> ByteString -> IO ValidPathInfo
queryPathInfo store path = do
  _ <- either (throwIO . storeError) pure (storePath store path)
  row <- queryOne store (statementValidPath store)
    [Bytes path]
  case row of
    Just [Integer identifier, Bytes hashField, Integer registered, deriver, narSize] -> do
      hash <- either (throwIO . storeError) pure (parseHashField path hashField)
      references <- queryReferencesById store identifier
      pure ValidPathInfo
        { infoId = identifier
        , infoPath = path
        , infoHash = hash
        , infoDeriver = case deriver of Bytes value -> value; _ -> B.empty
        , infoReferences = references
        , infoRegistrationTime = fromIntegral registered
        , infoNarSize = case narSize of Integer value -> fromIntegral value; _ -> 0
        }
    _ -> throwIO (storeError ("path `" ++ C.unpack path ++ "' is not valid"))

queryReferencesById :: Store -> Int64 -> IO [ByteString]
queryReferencesById store identifier = sort . concat <$> queryRowsStatement store (statementReferences store)
  [Integer identifier]

queryPathHash :: Store -> ByteString -> IO ByteString
queryPathHash store = fmap infoHash . queryPathInfo store

queryReferences :: Store -> ByteString -> IO [ByteString]
queryReferences store = fmap infoReferences . queryPathInfo store

queryReferrers :: Store -> ByteString -> IO [ByteString]
queryReferrers store path = do
  _ <- either (throwIO . storeError) pure (storePath store path)
  sort . concat <$> queryRowsStatement store (statementReferrers store)
    [Bytes path]

queryDeriver :: Store -> ByteString -> IO ByteString
queryDeriver store = fmap infoDeriver . queryPathInfo store

queryValidDerivers :: Store -> ByteString -> IO [ByteString]
queryValidDerivers store path = do
  _ <- either (throwIO . storeError) pure (storePath store path)
  sort . concat <$> queryRowsStatement store (statementValidDerivers store)
    [Bytes path]

queryDerivationOutputs :: Store -> ByteString -> IO [ByteString]
queryDerivationOutputs store path = do
  identifier <- pathId store path
  rows <- queryRowsStatement store (statementDerivationOutputs store) [Integer identifier]
  pure (sort [path | [_, path] <- rows])

queryDerivationOutputNames :: Store -> ByteString -> IO [ByteString]
queryDerivationOutputNames store path = do
  identifier <- pathId store path
  rows <- queryRowsStatement store (statementDerivationOutputs store) [Integer identifier]
  pure (sort [name | [name, _] <- rows])

queryPathFromHashPart :: Store -> ByteString -> IO ByteString
queryPathFromHashPart store hashPart
  | B.length hashPart /= 32 = throwIO (storeError "invalid hash part")
  | otherwise = do
      let prefix = storeDirectory store <> "/" <> hashPart
      result <- queryRowsStatement store (statementHashPart store) [Bytes prefix]
      pure $ case result of
        [[path]] | B.isPrefixOf prefix path -> path
        _ -> B.empty

queryFailedPaths :: Store -> IO [ByteString]
queryFailedPaths store = sort . concat <$> queryRowsStatement store (statementFailedPaths store) []

hasPathFailed :: Store -> ByteString -> IO Bool
hasPathFailed store path = not . null <$> queryRows (database store)
  "select path from FailedPaths where path = ?;" [Bytes path]

parseHashField :: ByteString -> ByteString -> Either String ByteString
parseHashField path field = case B.break (== 58) field of
  (algorithmName', rest) | not (B.null rest) -> do
    algorithm <- algorithmFromName algorithmName'
    digest <- decodeBase16 (B.drop 1 rest)
    if B.length digest == digestLength algorithm
      then Right digest
      else Left ("corrupt hash in valid-path entry for `" ++ C.unpack path ++ "'")
  _ -> Left ("corrupt hash `" ++ C.unpack field ++ "' in valid-path entry for `" ++ C.unpack path ++ "'")
