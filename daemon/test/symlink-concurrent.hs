{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | Regression: concurrent makeSymlinkAtomic calls for the SAME link must all
-- succeed.  The HS daemon serves every client in a THREAD of one process
-- (Server.hs forkFinally handleClient), so a single fixed temp name
-- (link <> ".tmp-goonix") is shared by all of them: one client's removeLink
-- deletes another's temp, or symlink() fails EEXIST, or rename() fails ENOENT.
-- C++ forks a process per client and names its temp link.tmp-<pid>-<rand>
-- (gc.cc), so both clients succeed there.
--
-- Every call must succeed, the link must point at the target, and no temp may
-- be left behind.  Fails before the fix, passes after.
-- Run: daemon/test/symlink-concurrent.sh
module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import qualified Data.ByteString.Char8 as C
import Data.List (isInfixOf, sort)
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import qualified System.Posix.Files.ByteString as Files

import Goonix.Store.Files (makeSymlinkAtomic)

main :: IO ()
main = do
  args <- getArgs
  let base = case args of
        (d:_) -> C.pack d
        [] -> "/tmp/goonix-symlink-concurrent"
      rounds = 12 :: Int
      workers = 8 :: Int
      mkdir p = createDirectoryIfMissing True (C.unpack p)
      runRound r = do
        let dir = base <> "/" <> C.pack ("round" ++ show r)
            link = dir <> "/result"
            target = dir <> "/target"
        mkdir dir
        C.writeFile (C.unpack target) "x"
        -- All workers start together: a barrier makes the collision reliable
        -- rather than dependent on scheduling luck.
        start <- newEmptyMVar
        dones <- mapM (\_ -> do
          done <- newEmptyMVar
          _ <- forkIO $ do
            takeMVar start
            result <- try (makeSymlinkAtomic target link)
            putMVar done (result :: Either SomeException ())
          pure done) [1 .. workers]
        mapM_ (\_ -> putMVar start ()) [1 .. workers]
        results <- mapM takeMVar dones
        let failures = [show e | Left e <- results]
        resolved <- try (Files.readSymbolicLink link)
        let pointsRight = case resolved of
              Right t -> t == target
              Left (_ :: SomeException) -> False
        entries <- listDirectory (C.unpack dir)
        let temps = filter (isInfixOf ".tmp") entries
        pure (if pointsRight then 0 else 1,
              failures ++ map ("leftover-temp " ++) temps)
      go 0 acc = pure acc
      go n (bad, problems) = do
        (b, p) <- runRound (rounds - n)
        go (n - 1) (bad + b, problems ++ p)
  (badLinks, problems) <- go rounds (0, [])
  mapM_ (hPutStrLn stderr . ("  " ++)) (take 6 (sort problems))
  if null problems && badLinks == 0
    then putStrLn ("SYMLINK_CONCURRENT: PASS " ++ show (rounds * workers) ++ " calls")
    else do
      putStrLn ("SYMLINK_CONCURRENT: FAIL " ++ show (length problems)
        ++ " problem(s), " ++ show badLinks ++ " round(s) with a wrong link")
      exitFailure