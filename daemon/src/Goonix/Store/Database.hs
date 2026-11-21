{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- Small SQLite FFI for the daemon's exact schema.  No text conversion is
-- used for paths: SQLite values are copied as bytes, as in the C++ daemon.
module Goonix.Store.Database
  ( Database
  , Statement
  , Value (..)
  , openReadOnly
  , openReadWrite
  , initializeSchema
  , initializeSchemaSql
  , closeDatabase
  , withDatabaseLock
  , withSchemaLock
  , withReadOnly
  , withReadWrite
  , execute
  , DatabaseBusy (..)
  , withTransaction
  , prepare
  , closeStatement
  , withStatement
  , bindValues
  , query
  , queryValues
  , queryRows
  , databaseError
  ) where

import Control.Exception (Exception, bracket, bracketOnError, onException, throwIO)
import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, retry, writeTVar)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Int (Int64)
import Data.Word (Word64)
import System.IO.Unsafe (unsafePerformIO)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt (..), CLLong (..), CUChar (..))
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Ptr (FunPtr, Ptr, castPtr, castPtrToFunPtr, intPtrToPtr, nullPtr)
import Foreign.Storable (peek)

data Database = Database (Ptr ()) !(TVar (Maybe (ThreadId, Int)))
data Statement = Statement ByteString (Ptr ()) (TVar (Maybe (ThreadId, Int)))

data DatabaseBusy = DatabaseBusy !String deriving (Show)
instance Exception DatabaseBusy

data Value = Integer !Int64 | Bytes !ByteString | Null
  deriving (Eq, Ord, Show)

-- Distinct client Store values have distinct SQLite handles.  Their one-time
-- schema check/creation must still be atomic across those handles: another
-- thread can prepare a statement after ValidPaths appears but before Refs or
-- DerivationOutputs has been created.
{-# NOINLINE schemaLock #-}
schemaLock :: MVar ()
schemaLock = unsafePerformIO (newMVar ())

-- Cover SQLite's WAL setup as well as schema and statement creation.  Opening
-- separate handles concurrently can otherwise return SQLITE_BUSY before the
-- per-handle lock exists.
withSchemaLock :: IO a -> IO a
withSchemaLock = withMVar schemaLock . const

foreign import ccall unsafe "sqlite3_open_v2"
  c_open :: CString -> Ptr (Ptr ()) -> CInt -> CString -> IO CInt
foreign import ccall unsafe "sqlite3_close_v2"
  c_close :: Ptr () -> IO CInt
foreign import ccall unsafe "sqlite3_errmsg"
  c_errmsg :: Ptr () -> IO CString
foreign import ccall unsafe "sqlite3_prepare_v2"
  c_prepare :: Ptr () -> CString -> CInt -> Ptr (Ptr ()) -> Ptr CString -> IO CInt
foreign import ccall unsafe "sqlite3_finalize"
  c_finalize :: Ptr () -> IO CInt
foreign import ccall unsafe "sqlite3_reset"
  c_reset :: Ptr () -> IO CInt
foreign import ccall unsafe "sqlite3_clear_bindings"
  c_clear_bindings :: Ptr () -> IO CInt
foreign import ccall unsafe "sqlite3_bind_null"
  c_bind_null :: Ptr () -> CInt -> IO CInt
foreign import ccall unsafe "sqlite3_bind_int64"
  c_bind_int64 :: Ptr () -> CInt -> CLLong -> IO CInt
foreign import ccall unsafe "sqlite3_bind_text64"
  c_bind_text :: Ptr () -> CInt -> CString -> Word64 -> FunPtr (Ptr () -> IO ()) -> CUChar -> IO CInt
foreign import ccall unsafe "sqlite3_step"
  c_step :: Ptr () -> IO CInt
foreign import ccall unsafe "sqlite3_column_count"
  c_column_count :: Ptr () -> IO CInt
foreign import ccall unsafe "sqlite3_column_type"
  c_column_type :: Ptr () -> CInt -> IO CInt
foreign import ccall unsafe "sqlite3_column_int64"
  c_column_int64 :: Ptr () -> CInt -> IO CLLong
foreign import ccall unsafe "sqlite3_column_blob"
  c_column_blob :: Ptr () -> CInt -> IO (Ptr CUChar)
foreign import ccall unsafe "sqlite3_column_bytes"
  c_column_bytes :: Ptr () -> CInt -> IO CInt
foreign import ccall unsafe "sqlite3_busy_timeout"
  c_busy_timeout :: Ptr () -> CInt -> IO CInt
foreign import ccall unsafe "sqlite3_complete"
  c_complete :: CString -> IO CInt

-- SQLITE_TRANSIENT makes SQLite copy bound byte strings before this returns.
transient :: FunPtr (Ptr () -> IO ())
transient = castPtrToFunPtr (intPtrToPtr (-1))

openReadOnly :: FilePath -> IO Database
openReadOnly = openDatabase 0x1

initializeSchema :: Database -> FilePath -> IO ()
initializeSchema db schemaPath = initializeSchemaSql db =<< B.readFile schemaPath

initializeSchemaSql :: Database -> ByteString -> IO ()
initializeSchemaSql db sql = withDatabaseLock db $ do
  rows <- queryValues db "select name from sqlite_master where type='table' and name='ValidPaths';" []
  when (null rows) $ do
    let statements = completeStatements sql
    mapM_ (\statement -> unless (B.null (B.dropWhile (<= 32) statement)) (execute db statement [])) statements

completeStatements :: ByteString -> [ByteString]
completeStatements input = go input B.empty []
  where
    go rest current acc
      | B.null rest = reverse (if B.null current then acc else current:acc)
      | otherwise =
          let (line, remainder) = B.break (== 59) rest
              current' = current <> line
          in if B.null remainder
               then reverse (current':acc)
               else do
                 let candidate = current' <> ";"
                 if completeSql candidate
                   then go (B.drop 1 remainder) B.empty (candidate:acc)
                   else go (B.drop 1 remainder) candidate acc
    completeSql bytes = unsafePerformIO (B.useAsCString bytes c_complete) /= 0

openReadWrite :: FilePath -> IO Database
openReadWrite = openDatabase 0x6

openDatabase :: CInt -> FilePath -> IO Database
openDatabase flags path = do
  database <- mallocBytes 8
  result <- withCString path $ \name -> c_open name database flags nullPtr
  handle <- peek database
  free database
  if result /= 0 || handle == nullPtr
    then do
      message <- if handle == nullPtr then pure "cannot open SQLite database" else do
        lock <- newTVarIO Nothing
        databaseError (Database handle lock)
      _ <- if handle == nullPtr then pure 0 else c_close handle
      throwIO (userError message)
    else do
      lock <- newTVarIO Nothing
      let db = Database handle lock
      check db =<< c_busy_timeout handle 60000
      execute db "pragma foreign_keys = on;" []
      execute db "pragma main.journal_mode = wal;" []
      pure db

withDatabaseLock :: Database -> IO a -> IO a
withDatabaseLock (Database _ owner) action = bracket acquire release (const action)
  where
    acquire = do
      self <- myThreadId
      atomically $ do
        current <- readTVar owner
        case current of
          Nothing -> writeTVar owner (Just (self, 1))
          Just (held, count) | held == self -> writeTVar owner (Just (self, count + 1))
          _ -> retry
      pure self
    release self = atomically $ do
      current <- readTVar owner
      case current of
        Just (held, count) | held == self && count > 1 -> writeTVar owner (Just (self, count - 1))
        Just (held, 1) | held == self -> writeTVar owner Nothing
        _ -> pure ()

closeDatabase :: Database -> IO ()
closeDatabase database@(Database handle _) = withDatabaseLock database $ do
  _ <- c_close handle
  pure ()

withReadOnly :: FilePath -> (Database -> IO a) -> IO a
withReadOnly path = bracket (openReadOnly path) closeDatabase

withReadWrite :: FilePath -> (Database -> IO a) -> IO a
withReadWrite path = bracket (openReadWrite path) closeDatabase

execute :: Database -> ByteString -> [Value] -> IO ()
execute database sql values = withStatement database sql $ \statement -> do
  _ <- query database statement values
  pure ()

withTransaction :: Database -> IO a -> IO a
withTransaction database action = withDatabaseLock database $ do
  execute database "begin;" []
  (action >>= \result -> execute database "commit;" [] >> pure result)
    `onException` execute database "rollback;" []

prepare :: Database -> ByteString -> IO Statement
prepare database@(Database handle lock) sql = withDatabaseLock database $
  bracketOnError (mallocBytes 8) free $ \statement -> do
    result <- B.useAsCStringLen sql $ \(text, len) ->
      c_prepare handle text (fromIntegral len) statement nullPtr
    pointer <- peek statement
    if result /= 0 || pointer == nullPtr
      then databaseError database >>= \message -> throwIO (userError ("SQLite prepare `" ++ C.unpack sql ++ "': " ++ message))
      else pure (Statement sql pointer lock)

closeStatement :: Statement -> IO ()
closeStatement (Statement _ statement _) = do
  _ <- c_finalize statement
  pure ()

withStatement :: Database -> ByteString -> (Statement -> IO a) -> IO a
withStatement database sql = bracket (prepare database sql) closeStatement

bindValues :: Database -> Statement -> [Value] -> IO ()
bindValues database statement values = do
  check database =<< c_reset (statementPtr statement)
  check database =<< c_clear_bindings (statementPtr statement)
  mapM_ bind (zip [1..] values)
  where
    bind (index, value) = case value of
      Null -> check database =<< c_bind_null (statementPtr statement) index
      Integer number -> check database =<< c_bind_int64 (statementPtr statement) index (fromIntegral number)
      Bytes bytes -> B.useAsCStringLen bytes $ \(pointer, len) ->
        check database =<< c_bind_text (statementPtr statement) index pointer (fromIntegral len) transient 1

query :: Database -> Statement -> [Value] -> IO [[Value]]
query database statement values = withDatabaseLock database $ do
  bindValues database statement values
  rows statement []
  where
    rows current@(Statement sql handle lock) acc = do
      result <- c_step handle
      case result of
        100 -> do
          count <- c_column_count handle
          row <- mapM (column handle) [0 .. count - 1]
          rows (Statement sql handle lock) (row:acc)
        101 -> pure (reverse acc)
        _ | result == 5 || result == 6 -> throwIO (DatabaseBusy ("SQLite step `" ++ C.unpack sql ++ "': database is busy"))
          | otherwise -> databaseError database >>= \message -> throwIO (userError ("SQLite step `" ++ C.unpack sql ++ "': " ++ message))

column :: Ptr () -> CInt -> IO Value
column statement index = do
  kind <- c_column_type statement index
  case kind of
    1 -> Integer . fromIntegral <$> c_column_int64 statement index
    5 -> pure Null
    _ -> do
      pointer <- c_column_blob statement index
      size <- c_column_bytes statement index
      if size < 0 || (size > 0 && pointer == nullPtr)
        then throwIO (userError "invalid SQLite column value")
        else Bytes <$> B.packCStringLen (castPtr pointer, fromIntegral size)

queryValues :: Database -> ByteString -> [Value] -> IO [[Value]]
queryValues database sql values = withStatement database sql $ \statement ->
  query database statement values

queryRows :: Database -> ByteString -> [Value] -> IO [[ByteString]]
queryRows database sql values = do
  rows <- queryValues database sql values
  pure (map (map bytes) rows)
  where
    bytes (Bytes value) = value
    bytes Null = B.empty
    bytes (Integer value) = error ("integer SQLite value where bytes expected: " ++ show value)

statementPtr :: Statement -> Ptr ()
statementPtr (Statement _ pointer _) = pointer

check :: Database -> CInt -> IO ()
check database result
  | result == 0 = pure ()
  | otherwise = databaseError database >>= throwIO . userError

databaseError :: Database -> IO String
databaseError (Database handle _) = do
  message <- c_errmsg handle
  if message == nullPtr then pure "unknown SQLite error" else peekCString message
