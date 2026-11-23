{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- Regression (reviewer point 1): a hook that dies or closes its output before
-- replying must make requestOffload RAISE within a bounded time, not spin forever
-- flooding the client with newlines.
--
-- Before the fix, receiveLine returned the partial line at EOF ("" when nothing
-- was read).  requestOffload's replyLine saw no "# " prefix, emitted "\n" and
-- called receiveLine again, which returned "" again — an endless full-CPU loop.
-- After the fix receiveLine throws storeError "offload hook closed its output" at
-- EOF (as C++ readLine / Substitute.receiveLine do), so requestOffload raises.
--
-- Construct a Hook over a pipe whose write end is CLOSED immediately (EOF), run
-- requestOffload while counting emitted bytes and timing it (+RTS -A1m -N).  PASS
-- when requestOffload raises quickly AND emits no newline flood.  FAILS before the
-- fix (spins / times out, or floods).
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.IORef (newIORef, readIORef, modifyIORef', writeIORef)
import Data.List (isInfixOf)
import GHC.Clock (getMonotonicTime)
import Goonix.Build.Offload (Hook (..), requestOffload)
import System.Posix.IO.ByteString (createPipe, closeFd, fdToHandle)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  (outFd, peerFd) <- createPipe
  -- Close the write end at once: the hook "died" without replying -> EOF on outFd.
  closeFd peerFd
  -- A writable dummy input handle so requestOffload's sendLine succeeds and the
  -- read reaches the closed output fd (the EOF under test).  Keep inRead OPEN so
  -- the input pipe is writable (closing it would make sendLine fail EPIPE first).
  (_inRead, inWrite) <- createPipe
  inputHandle <- fdToHandle inWrite
  stopped <- newEmptyMVar
  let hook = Hook { hookInput = inputHandle, hookOutputFd = outFd
                  , hookBuilder = inputHandle, hookPid = 0, hookStopped = stopped }
  emitted <- newIORef (0 :: Int)
  result <- newIORef (Nothing :: Maybe (Either String ()))
  resultAt <- newIORef (0 :: Double)
  started <- newEmptyMVar
  s <- getMonotonicTime
  _ <- forkIO $ do
    putMVar started ()
    r <- try (requestOffload hook (\b -> modifyIORef' emitted (+ B.length b))
                             True "x86_64-linux" "/gnu/store/x.drv" [])
    t <- getMonotonicTime
    writeIORef resultAt (t - s)
    case r of
      Left e -> writeIORef result (Just (Left (show (e :: SomeException))))
      Right _ -> writeIORef result (Just (Right ()))
  takeMVar started
  threadDelay 2000000                  -- give it 2s; a correct fix raises in ms
  r <- readIORef result
  n <- readIORef emitted
  elapsed <- readIORef resultAt
  hPutStrLn stderr ("offload-eof: raised-after=" ++ show elapsed ++ "s emitted=" ++ show n ++ " bytes result=" ++ show r)
  case r of
    -- The fix raises a proper storeError "offload hook closed its output" at EOF
    -- (receiveLine catches the fdRead EOF exception and throws, as C++ readLine /
    -- Substitute.receiveLine do).  Before the fix the raw fdRead EOF exception
    -- propagated instead (and the B.null-byte partial-line branch was a latent
    -- endless-loop flood had fdRead returned "" rather than thrown).  Require the
    -- storeError, bounded time, and no newline flood.
    Just (Left msg) | "offload hook closed its output" `isInfixOf` msg && n < 1000 && elapsed < 1.5 ->
      hPutStrLn stderr "OFFLOAD_EOF_PASS (requestOffload raised storeError at EOF, no newline flood)"
    Just (Left _) -> do
      hPutStrLn stderr "OFFLOAD_EOF_FAIL (raised, but not the EOF storeError, or flooded/took too long)"
      fail "offload-eof regression failed"
    Just (Right _) -> do
      hPutStrLn stderr "OFFLOAD_EOF_FAIL (requestOffload returned instead of raising at EOF)"
      fail "offload-eof regression failed"
    Nothing -> do
      hPutStrLn stderr "OFFLOAD_EOF_FAIL (requestOffload still spinning after 2s — the EOF endless loop)"
      fail "offload-eof regression failed"