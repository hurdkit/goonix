{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | CA finalisation against an UNREGISTERED leftover at the final path.
--
-- C++ finaliseContentOutput (nix/libstore/ca.cc) branches three ways when the
-- content-addressed final path already exists.  An unregistered tree that is
-- not a staged sibling of this build is a leftover from a daemon that died
-- between the rename and registration: it is deleted and the output finalised
-- fresh.  A staged sibling or a registered item is verified and reused, and a
-- registered item whose content differs is a refused collision.
--
-- registerCaBuiltOutputs finalises every content output before registering any
-- of them, so a build that fails after the first rename routinely leaves such a
-- leftover.  The Haskell port used to compare ANY existing tree with
-- sameContent, so the leftover was reported as "CA content address collision
-- at ...: existing item differs" (counted CA gate: HS ca-policy 81/3 against
-- CXX 84/0).  This program pins the branches against a scratch store.
--
-- Build and run with daemon/test/ca-leftover.sh.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)
import System.Posix.ByteString (RawFilePath)
import qualified System.Posix.Files.ByteString as Files

import Goonix.Store.Ca (contentAddressedPath, tokenPath, treeHash)
import Goonix.Store.CaBuild (finaliseContentOutput, Finalised (..))
import Goonix.Store.Database (Value (..), execute, withTransaction)
import Goonix.Store.Files (deleteTree)
import Goonix.Store.Nar (hashNar, dumpNar)
import Goonix.Store.ReadOnly (Store (..), openStore, closeStore, isValidPath)
import Goonix.Store.Writing (registerPath)

check :: IORef Int -> String -> Bool -> IO ()
check failures label ok = do
  hPutStrLn stderr ((if ok then "ok   " else "FAIL ") ++ label)
  unless ok (modifyIORef' failures (+ 1))

-- | Write a one-file tree whose content is CONTENT, with the modes and mtime a
-- canonicalised store item has (0444, mtime 1), so its tree hash is stable.
writeTree :: RawFilePath -> ByteString -> IO ()
writeTree path content = do
  -- A previous check may have left this tree canonicalised read-only; the
  -- daemon likewise rewrites a token tree that already exists.
  present <- Files.fileExist path
  when present (deleteTree path)
  createDirectoryIfMissing True (C.unpack path)
  let file = path <> "/payload"
  B.writeFile (C.unpack file) content
  Files.setFileMode file 0o444
  Files.setFileMode path 0o555

-- | Run finaliseContentOutput over a freshly written token tree, catching the
-- daemon's refusal so a check can assert on it.
finalise :: Store -> RawFilePath -> RawFilePath -> ByteString -> ByteString
         -> IO (Either String Finalised)
finalise store storeDir token output content = do
  writeTree token content
  outcome <- try (finaliseContentOutput store storeDir token output "probe"
                  [token] Map.empty "" (\_ -> pure ()))
  pure $ case outcome of
    Left exception -> Left (show (exception :: SomeException))
    Right value -> Right value

-- | Drop the ValidPaths row, leaving the tree on disk: the state a daemon that
-- died between the rename and registration leaves behind.
invalidate :: Store -> ByteString -> IO ()
invalidate store path = withTransaction (database store) $ do
  execute (database store)
    "delete from Refs where referrer = (select id from ValidPaths where path = ?);"
    [Bytes path]
  execute (database store) "delete from ValidPaths where path = ?;" [Bytes path]

main :: IO ()
main = do
  args <- getArgs
  let directory = case args of
        (d:_) -> d
        [] -> "/tmp/ca-leftover-test"
      storeDir = C.pack directory <> "/store"
      stateDir = C.pack directory <> "/state"
  createDirectoryIfMissing True (C.unpack storeDir)
  createDirectoryIfMissing True (C.unpack stateDir)
  -- The daemon keeps the store writable for the duration of a build and
  -- canonicaliseAndHash sets 0o755 around its pass; a rename into the store
  -- needs that here too.
  Files.setFileMode storeDir 0o755
  failures <- newIORef 0
  let ok = check failures
  store <- openStore storeDir (C.unpack (stateDir <> "/db.sqlite")) stateDir
  let token = tokenPath storeDir "out" "probe"
      content = "leftover-probe-content"
      payload = "/payload"

  -- The final path this content selects, computed as finaliseContentOutput does.
  let probe = storeDir <> "/.leftover-probe"
  present <- Files.fileExist probe
  when present (deleteTree probe)
  writeTree probe content
  built <- treeHash probe
  deleteTree probe
  let final = contentAddressedPath storeDir "out" "probe" built []

  -- 1. No existing item: finalise fresh, rename, created = True.
  outcome1 <- finalise store storeDir token "out" content
  case outcome1 of
    Left message -> do
      ok "fresh finalisation succeeds" False
      hPutStrLn stderr ("  " ++ message)
    Right value -> do
      ok "fresh finalisation succeeds" True
      ok "fresh finalisation selects the content address" (finalPath value == final)
      ok "fresh finalisation reports created" (finalCreated value)
  nar <- hashNar final
  size <- fromIntegral . B.length <$> dumpNar final
  registerPath store final nar size [] ""

  -- 2. A registered identical item is reused, created = False.
  outcome2 <- finalise store storeDir token "out" content
  case outcome2 of
    Left message -> do
      ok "a registered identical item is reused" False
      hPutStrLn stderr ("  " ++ message)
    Right value -> do
      ok "a registered identical item is reused" True
      ok "reuse reports not-created" (not (finalCreated value))
      ok "reuse keeps the item valid" =<< isValidPath store final

  -- 3. A registered DIFFERENT item at the same address is a refused collision.
  --    Replace the registered tree's content without touching the database row,
  --    which is what corruption looks like to the finaliser.
  let writeFinal text = do
        -- rewriteTree restores each directory's original (read-only) mode, so
        -- make the tree writable again before editing it, as the daemon's
        -- withWritableDirectory does.
        Files.setFileMode final 0o755
        Files.setFileMode (final <> payload) 0o644
        B.writeFile (C.unpack (final <> payload)) text
        Files.setFileMode (final <> payload) 0o444
        Files.setFileMode final 0o555
  writeFinal "different-content"
  outcome3 <- finalise store storeDir token "out" content
  case outcome3 of
    Left message ->
      ok "a registered differing item is refused as a collision"
        ("existing item differs" `isInfixOf` message)
    Right _ -> ok "a registered differing item is refused as a collision" False
  writeFinal content

  -- 4. THE REGRESSION.  An UNREGISTERED leftover at the final path: drop the
  --    database row but leave the tree, exactly as a daemon that died between
  --    the rename and registration does.  The leftover's content also DIFFERS,
  --    as the counted gate's did (245 files left at mode 644 by a partly
  --    finalised tree, so its NAR hash differed from the token tree's).
  --    Comparing it -- the old behaviour -- reports a bogus collision; the C++
  --    daemon deletes the leftover and finalises fresh.
  invalidate store final
  writeFinal "leftover-from-a-dead-daemon"
  Files.setFileMode (final <> payload) 0o644
  ok "the leftover is unregistered" . not =<< isValidPath store final
  ok "the leftover tree is still on disk" =<< Files.fileExist final
  outcome4 <- finalise store storeDir token "out" content
  case outcome4 of
    Left message -> do
      ok "an unregistered leftover is replaced, not refused" False
      hPutStrLn stderr ("  " ++ message)
    Right value -> do
      ok "an unregistered leftover is replaced, not refused" True
      ok "the replaced leftover selects the content address" (finalPath value == final)
      ok "replacing the leftover reports created" (finalCreated value)
  replaced <- B.readFile (C.unpack (final <> payload))
  ok "the replaced tree holds the new content, not the leftover's"
    (replaced == content)
  mode <- Files.fileMode <$> Files.getSymbolicLinkStatus (final <> payload)
  ok "the replaced tree is canonicalised read-only" (mode .&. 0o222 == 0)

  closeStore store
  count <- readIORef failures
  if count == 0
    then hPutStrLn stderr "ca-leftover: all checks passed"
    else die ("ca-leftover: " ++ show count ++ " check(s) failed")