{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Bits ((.&.))
import qualified Data.ByteString.Char8 as BC
import Data.IORef
import Data.List (isInfixOf)
import Goonix.Store.Files
import System.Directory
import System.Environment (getArgs)
import System.Exit
import System.IO
import System.Posix.Files (fileMode, getSymbolicLinkStatus, readSymbolicLink, setFileMode)
import System.Process
import System.Timeout (timeout)

-- A small external fcntl client; Perl, not a second copy of the Haskell table.
probe :: FilePath -> Bool -> IO String
probe path exclusive = do
  out <- readProcess "perl"
    [ "-Mstrict", "-Mwarnings", "-MFcntl=F_SETLK,F_WRLCK,F_RDLCK"
    , "-e", unlines
        [ "open my $fd, '+<', $ARGV[0] or die $!;"
        , "my $type = $ARGV[1] eq 'x' ? F_WRLCK : F_RDLCK;"
        , "my $lock = pack('s s l l i', $type, 0, 0, 0, 0);"
        , "print fcntl($fd, F_SETLK, $lock) ? qq(free\\n) : qq(held\\n);"
        ]
    , path, if exclusive then "x" else "s" ] ""
  pure (takeWhile (/= '\n') out)

externalHolder :: FilePath -> Bool -> IO (IO ())
externalHolder path delete = do
  (Just input, Just output, _, handle) <- createProcess
    (proc "perl"
      [ "-Mstrict", "-Mwarnings", "-MFcntl=F_SETLKW,F_WRLCK"
      , "-e", unlines
          [ "open my $fd, '+>>', $ARGV[0] or die $!;"
          , "my $lock = pack('s s l l i', F_WRLCK, 0, 0, 0, 0);"
          , "fcntl($fd, F_SETLKW, $lock) or die $!;"
          , "print qq(locked\\n);"
          , "STDOUT->autoflush(1);"
          , "<STDIN>;"
          , "if ($ARGV[1] eq 'delete') { unlink $ARGV[0]; print $fd 'd'; }"
          , "close $fd;"
          ]
      , path, if delete then "delete" else "keep" ])
      { std_in = CreatePipe, std_out = CreatePipe }
  line <- hGetLine output
  unless (line == "locked") (die "external holder did not lock")
  pure (hClose input >> void (waitForProcess handle))

check :: String -> Bool -> IO ()
check name ok = unless ok (die ("FAIL: " ++ name))

within :: String -> IO a -> IO a
within name action = timeout 10000000 action >>= maybe (die ("FAIL: timed out: " ++ name)) pure

spawn :: IO () -> IO (ThreadId, MVar (Either SomeException ()))
spawn action = do
  done <- newEmptyMVar
  thread <- forkIOWithUnmask $ \unmask -> try (unmask action) >>= putMVar done
  pure (thread, done)

finished :: String -> MVar (Either SomeException ()) -> IO ()
finished name done = within name (takeMVar done) >>= either (\e -> die ("FAIL: " ++ name ++ ": " ++ show e)) pure

notYet :: String -> MVar () -> IO ()
notYet name entered = do
  threadDelay 100000
  inside <- isEmptyMVar entered
  check name inside

waitForBusyLock :: IO ()
waitForBusyLock = do
  installed <- timeout 1000000 (waitForEntry 0)
  check "waiter installs its lock table entry" (case installed of Just () -> True; Nothing -> False)
  where
    waitForEntry 0 = pure ()
    waitForEntry _ = do
      n <- lockTableSize
      if n == 0 then threadDelay 1000 >> waitForEntry 0 else pure ()

descriptorsOn :: FilePath -> IO Int
descriptorsOn path = do
  fds <- listDirectory "/proc/self/fd"
  targets <- forM fds $ \fd -> try (readSymbolicLink ("/proc/self/fd/" ++ fd)) :: IO (Either SomeException FilePath)
  pure (length [() | Right target <- targets, target == path])

descriptors :: IO Int
descriptors = length <$> listDirectory "/proc/self/fd"

main :: IO ()
main = do
  [given] <- getArgs
  createDirectoryIfMissing True given
  directory <- makeAbsolute given
  let gc = directory ++ "/gc.lock"
      item = directory ++ "/item.lock"
  baseline <- descriptors

  -- 1. Exclusive excludes exclusive, between threads.
  do
    let released = directory ++ "/released.lock"
    withGCLock (BC.pack released) (pure ())
    lockTableSize >>= check "table empty after single holder" . (== 0)
    entered1 <- newEmptyMVar; leave1 <- newEmptyMVar; entered2 <- newEmptyMVar
    (_, done1) <- spawn $ withGCLock (BC.pack gc) (putMVar entered1 () >> takeMVar leave1)
    within "first writer enters" (readMVar entered1)
    (_, done2) <- spawn $ withGCLock (BC.pack gc) (putMVar entered2 ())
    notYet "second writer waits for the first" entered2
    probe gc False >>= check "another process sees the exclusive lock" . (== "held")
    putMVar leave1 ()
    finished "first writer" done1
    finished "second writer" done2
    lockTableSize >>= check "table empty after writers" . (== 0)
  putStrLn "ok 1 exclusive excludes exclusive"

  -- 2. One descriptor; seven readers leaving do not drop the last one's lock.
  do
    inside <- newIORef (0 :: Int)
    readers <- forM [1 .. 8 :: Int] $ \_ -> do
      entered <- newEmptyMVar; leave <- newEmptyMVar
      (_, done) <- spawn $ withGCReadLock (BC.pack gc) $ do
        atomicModifyIORef' inside (\n -> (n + 1, ()))
        putMVar entered ()
        takeMVar leave
      pure (entered, leave, done)
    forM_ readers $ \(entered, _, _) -> within "reader enters" (readMVar entered)
    readIORef inside >>= check "eight readers inside together" . (== 8)
    descriptorsOn gc >>= check "one descriptor for eight readers" . (== 1)
    probe gc True >>= check "exclusive refused to another process" . (== "held")
    probe gc False >>= check "shared granted to another process" . (== "free")
    forM_ (init readers) $ \(_, leave, done) -> putMVar leave () >> finished "reader" done
    probe gc True >>= check "lock still held after seven readers left" . (== "held")
    descriptorsOn gc >>= check "descriptor still open for the last reader" . (== 1)
    let (_, leave, done) = last readers
    putMVar leave () >> finished "last reader" done
    probe gc True >>= check "lock free after the last reader" . (== "free")
    descriptorsOn gc >>= check "descriptor closed after the last reader" . (== 0)
  putStrLn "ok 2 readers share one descriptor"

  -- 3. A writer waits for readers, a reader waits for a writer.
  do
    readerIn <- newEmptyMVar; readerLeave <- newEmptyMVar; writerIn <- newEmptyMVar; writerLeave <- newEmptyMVar
    (_, reader) <- spawn $ withGCReadLock (BC.pack gc) (putMVar readerIn () >> takeMVar readerLeave)
    within "reader enters" (readMVar readerIn)
    (_, writer) <- spawn $ withGCLock (BC.pack gc) (putMVar writerIn () >> takeMVar writerLeave)
    notYet "writer waits for the reader" writerIn
    putMVar readerLeave () >> finished "reader" reader
    within "writer enters" (readMVar writerIn)
    lateIn <- newEmptyMVar
    (_, late) <- spawn $ withGCReadLock (BC.pack gc) (putMVar lateIn ())
    notYet "reader waits for the writer" lateIn
    putMVar writerLeave () >> finished "writer" writer
    finished "late reader" late
  putStrLn "ok 3 readers and writers wait for each other"

  -- 4. Cancellation leaves no table slot or descriptor.
  do
    entered <- newEmptyMVar
    (holder, holderDone) <- spawn $ withGCLock (BC.pack gc) (putMVar entered () >> threadDelay maxBound)
    within "holder enters" (readMVar entered)
    waiterIn <- newEmptyMVar
    (waiter, waiterDone) <- spawn $ withGCReadLock (BC.pack gc) (putMVar waiterIn ())
    notYet "waiter waits" waiterIn
    killThread waiter
    within "killed waiter ends" (takeMVar waiterDone) >>= check "waiter was killed" . either (const True) (const False)
    killThread holder
    within "killed holder ends" (takeMVar holderDone) >>= check "holder was killed" . either (const True) (const False)
    lockTableSize >>= check "table empty after kills" . (== 0)
    probe gc True >>= check "lock free after the holder was killed" . (== "free")
    stop <- externalHolder gc False
    firstIn <- newEmptyMVar; secondIn <- newEmptyMVar
    (first, firstDone) <- spawn $ withGCLock (BC.pack gc) (putMVar firstIn ())
    waitForBusyLock
    (second, secondDone) <- spawn $ withGCReadLock (BC.pack gc) (putMVar secondIn ())
    notYet "thread waits for the other process" firstIn
    notYet "second thread waits too" secondIn
    killThread first
    within "first ends" (takeMVar firstDone) >>= check "first was killed" . either (const True) (const False)
    notYet "second still waits for the other process" secondIn
    killThread second
    within "second ends" (takeMVar secondDone) >>= check "second was killed" . either (const True) (const False)
    lockTableSize >>= check "table empty after kills during the wait" . (== 0)
    descriptorsOn gc >>= check "no descriptor left after kills during the wait" . (== 0)
    thirdIn <- newEmptyMVar
    (_, thirdDone) <- spawn $ withGCLock (BC.pack gc) (putMVar thirdIn ())
    notYet "third waits for the other process" thirdIn
    stop
    finished "third enters when the other process leaves" thirdDone
  putStrLn "ok 4 cancellation"

  -- 5. Nested exclusive acquisition is an error, not a hang.
  do
    result <- within "nested exclusive" $ try $
      withGCLock (BC.pack gc) (withGCLock (BC.pack gc) (pure ()))
    check "nested exclusive lock is refused" $ case result of
      Left e -> "deadlock" `isInfixOf` show (e :: IOException)
      Right () -> False
    lockTableSize >>= check "table empty after the refusal" . (== 0)
  putStrLn "ok 5 nested exclusive lock is an error"

  -- 6. Deleted lock files are never mistaken for the current lock.
  do
    withPathLock (BC.pack (directory ++ "/item")) (doesFileExist item >>= check "lock file exists while held")
    doesFileExist item >>= check "lock file deleted on release" . not
    stop <- externalHolder item True
    entered <- newEmptyMVar; leave <- newEmptyMVar
    (_, done) <- spawn $ withPathLock (BC.pack (directory ++ "/item")) (putMVar entered () >> takeMVar leave)
    notYet "thread waits for the other process" entered
    stop
    within "thread enters after the other process deleted the file" (readMVar entered)
    doesFileExist item >>= check "a new lock file exists"
    probe item True >>= check "the new file is locked" . (== "held")
    putMVar leave () >> finished "holder" done
    doesFileExist item >>= check "lock file deleted again" . not
  putStrLn "ok 6 deleted lock files"

  -- 7. Stress three paths, and check the directory's original mode survives.
  do
    setFileMode directory 0o555
    let paths = map BC.pack [gc, directory ++ "/item", directory ++ "/other"]
    states <- forM paths $ \_ -> newIORef (0 :: Int, 0 :: Int)
    bad <- newIORef False
    workers <- forM [1 .. 16 :: Int] $ \worker -> spawn $
      forM_ [1 .. 400 :: Int] $ \round -> do
        let index = (worker * 7 + round * 3) `mod` 3
            path = paths !! index
            state = states !! index
            exclusive = (worker + round) `mod` 4 == 0
            lock = if index == 0
              then if exclusive then withGCLock else withGCReadLock
              else withPathLock
        lock path $ do
          (readersNow, writersNow) <- atomicModifyIORef' state $ \(r, w) ->
            let next = if exclusive then (r, w + 1) else (r + 1, w) in (next, next)
          when (writersNow > 1 || (writersNow == 1 && readersNow > 0)) (writeIORef bad True)
          when (round `mod` 5 == 0) yield
          atomicModifyIORef' state $ \(r, w) -> (if exclusive then (r, w - 1) else (r - 1, w), ())
    forM_ workers $ \(_, done) -> finished "worker" done
    readIORef bad >>= check "no writer together with another holder" . not
    lockTableSize >>= check "table empty after the stress" . (== 0)
    mode <- fileMode <$> getSymbolicLinkStatus directory
    check "store directory mode restored" (mode .&. 0o777 == 0o555)
  putStrLn "ok 7 stress and directory mode"

  now <- descriptors
  check ("descriptors as at the start (" ++ show baseline ++ " then, " ++ show now ++ " now)") (now == baseline)
  putStrLn "lock table: PASS"
