{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE StrictData #-}

-- Waiting for a child process without holding a GHC capability.
--
-- The daemon is built -threaded -N.  getProcessStatus True False pid is a BLOCKING
-- waitpid: it holds the calling thread's capability until the child exits, and the
-- next GC needs EVERY capability to stop.  So one long-running build (the sandbox
-- helper) or offload hook would freeze every other client and build in the process
-- at its next GC.  C++ has no such problem because each client is its own process.
--
-- Poll with a NONBLOCKING waitpid (WNOHANG) and threadDelay, which releases the
-- capability between polls — the same pattern the daemon already uses for the
-- file-lock wait (Files.hs acquireExternal).  The RTS's own process support
-- (System.Process.waitForProcess) is deliberately NOT used: these children are
-- spawned by the C shims goonix_spawn_sandbox / goonix_spawn_offload, not by the
-- process library, so there is no ProcessHandle to wait on.  Re-registering the raw
-- pid with the RTS would risk a double reap against the existing waitpid calls.
--
-- A raw waitpid is used (not getProcessStatus False) because WNOHANG returns 0 while
-- the child still runs and -1/ECHILD when there is no child; getProcessStatus False
-- collapses both to Nothing, which would spin forever on a child that is gone.  The
-- status is decoded here (the child is already reaped by this waitpid).
module Goonix.Build.Wait
  ( waitProcessStatusNonBlocking
  ) where

import Control.Concurrent (threadDelay)
import Data.Bits ((.&.), shiftR)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import System.Exit (ExitCode (..))
import System.Posix.Process (ProcessStatus (..))
import System.Posix.Types (ProcessID, CPid(..))

foreign import ccall unsafe "waitpid"
  c_waitpid :: CInt -> Ptr CInt -> CInt -> IO CInt

wnohang :: CInt
wnohang = 1

-- | Wait for a child to exit or stop, polling without blocking a capability.
-- Returns the ProcessStatus once the child changes state; Nothing if there is no
-- such child (ECHILD).  Never holds the capability while the child runs.
waitProcessStatusNonBlocking :: ProcessID -> IO (Maybe ProcessStatus)
waitProcessStatusNonBlocking (CPid raw) = go
  where
    go = alloca $ \statusPtr -> do
      r <- c_waitpid (fromIntegral raw) statusPtr wnohang
      if r == 0
        then threadDelay 10000 >> go        -- still running; release the capability
        else if r < 0
          then pure Nothing                  -- ECHILD: no child to wait for
          else do
            status <- peek statusPtr
            pure (Just (decode (fromIntegral status)))
    -- Linux wait status: low 7 bits = terminating signal (0 = exited),
    -- bits 8..15 = exit code, 0x7f = stopped (WIFSTOPPED).
    decode :: Int -> ProcessStatus
    decode status
      | status .&. 0x7f == 0 = Exited (exitCode (status `shiftR` 8))
      | status .&. 0xff == 0x7f = Stopped (fromIntegral (status `shiftR` 8))
      | otherwise = Terminated (fromIntegral (status .&. 0x7f)) False
    exitCode 0 = ExitSuccess
    exitCode n = ExitFailure n