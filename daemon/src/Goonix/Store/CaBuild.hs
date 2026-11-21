{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
-- | goonix CA resolution and finalisation (HS-11, CA-1/CA-2).  Ported from the
-- verified C++ nix/libstore/ca.cc and build-ca.cc: resolveDerivation (input
-- choices replace placeholders), checkResolvedDerivation, the reserved-tree
-- checks, the bounded-chunk token rewrite with opaque-fragment refusal, the
-- inverse-tree verification, and finaliseContentOutput.
module Goonix.Store.CaBuild
  ( resolveDerivation
  , checkResolvedDerivation
  , checkInputAddressedPolicy
  , contentOutputOrder
  , finaliseContentOutput
  , Finalised (..)
  , replaceWhole
  , rewriteTree
  , checkReservedTree
  , inverseTree
  , sameContent
  , removeGoonixEnvironment
  , materialiseGoonixFiles
  , isStorePathStrict
  ) where

import Control.Exception (bracket, catch, throwIO, onException, SomeException)
import Control.Monad (forM, forM_, unless, when, foldM)
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString as B (hGetSome, hPut)
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import Goonix.Store.Base32 (base32Alphabet)
import Goonix.Store.Ca
import Goonix.Store.Derivation
import Goonix.Store.Files (directoryEntries, deleteTree, mkdirParents)
import Goonix.Store.Hash
import Goonix.Store.Nar (hashNar, dumpNar)
import Goonix.Store.Path (storePathToName, validateStoreName)
import Goonix.Store.References (scanReferences)
import System.Posix.ByteString (RawFilePath)
import System.Posix.Types (FileMode)
import qualified System.Posix.Files.ByteString as Files
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import System.IO (IOMode (..), withBinaryFile, openBinaryFile, hClose)

caError :: String -> IO a
caError message = throwIO (userError message)

-- | breakOn for the pinned bytestring (which lacks it): the prefix before the
-- first occurrence and the rest starting at it; ("", "") when absent... the
-- whole input and "" when the needle is absent.
breakOn :: ByteString -> ByteString -> (ByteString, ByteString)
breakOn needle haystack = go 0
  where
    go at
      | at + B.length needle > B.length haystack = (haystack, B.empty)
      | B.take (B.length needle) (B.drop at haystack) == needle =
          (B.take at haystack, B.drop at haystack)
      | otherwise = go (at + 1)

foreign import ccall unsafe "goonix_restore_mtime" c_restore_mtime :: CString -> CInt -> IO CInt

restoreMtime :: RawFilePath -> Bool -> IO ()
restoreMtime path nofollow =
  B.useAsCString path $ \pointer -> do
    result <- c_restore_mtime pointer (if nofollow then 1 else 0)
    when (result /= 0) (caError ("restoring timestamp of `" ++ C.unpack path ++ "'"))

baseName :: ByteString -> ByteString
baseName = snd . C.breakEnd (== '/')

hashPart :: ByteString -> ByteString
hashPart = B.take 32 . baseName

-- | Replace every occurrence of `from' with `to' (equal lengths).  Unless
-- opaque fragments are allowed, refuse any 8-byte fragment of `from' that
-- survives, and any UTF-16LE/UTF-32LE encoding of it (C++ replaceWhole).
replaceWhole :: ByteString -> ByteString -> ByteString -> ByteString -> Bool -> Either String ByteString
replaceWhole input from to file rejectOpaque
  | B.length from /= B.length to = Left "internal CA token length mismatch"
  | otherwise =
      let replaced = substitute input
      in if not rejectOpaque then Right replaced else case opaqueCheck replaced of
        Just err -> Left err
        Nothing -> Right replaced
  where
    substitute value = go value 0
      where
        go current at = case breakOn from (B.drop at current) of
          (before, rest) | B.null rest -> B.take at current <> before
                         | otherwise ->
            let at' = at + B.length before
            in go (B.take at' current <> to <> B.drop (at' + B.length from) current)
                  (at' + B.length to)
    opaqueCheck value = firstJust (fragmentChecks ++ utfChecks)
      where
        firstJust [] = Nothing
        firstJust (x:xs) = case x of
          Just err -> Just err
          Nothing -> firstJust xs
        fragmentChecks =
          [ case breakOn fragment value of
              (_, rest) | not (B.null rest) ->
                Just ("opaque self-reference fragment `" ++ C.unpack fragment ++ "' in `"
                  ++ C.unpack file ++ "' at byte " ++ show (B.length value - B.length rest))
              _ -> Nothing
          | i <- [0 .. B.length from - 8], let fragment = B.take 8 (B.drop i from) ]
        utfChecks =
          [ case breakOn encoded value of
              (_, rest) | not (B.null rest) ->
                Just ("UTF-" ++ show (width * 8) ++ " self-reference in `" ++ C.unpack file
                  ++ "' at byte " ++ show (B.length value - B.length rest))
              _ -> Nothing
          | width <- [2, 4 :: Int]
          , let encoded = B.concatMap (\c -> c `B.cons` B.replicate (width - 1) 0) from ]

-- | Scan a byte string for an unresolved placeholder: 32 reserved-alphabet
-- characters starting with 'e' followed by '-' (C++ checkReserved).
checkReserved :: ByteString -> ByteString -> Either String ()
checkReserved path bytes = go 0
  where
    go offset
      | offset + 33 > B.length bytes = Right ()
      | B.index bytes offset /= 101 = go (offset + 1)
      | not (B.all (`B.elem` "eout") (B.take 32 (B.drop offset bytes))) = go (offset + 1)
      | B.index bytes (offset + 32) /= 45 = go (offset + 1)
      | otherwise = Left ("unresolved goonix placeholder in `" ++ C.unpack path
          ++ "' at byte " ++ show offset)

-- | Stream a regular file through checkReserved, retaining 32 bytes across
-- read boundaries (C++ checkReservedFile).
checkReservedFile :: RawFilePath -> IO ()
checkReservedFile path = withBinaryFile (C.unpack path) ReadMode $ \handle ->
  let loop pending = do
        chunk <- B.hGetSome handle (128 * 1024)
        if B.null chunk
          then either caError pure (checkReserved path pending)
          else do
            let combined = pending <> chunk
            when (B.length combined > 32) (either caError pure (checkReserved path combined))
            loop (B.drop (max 0 (B.length combined - 32)) combined)
  in loop B.empty

-- | Refuse unresolved placeholders anywhere in an output tree: names, file
-- contents, symlink targets (C++ checkReservedTree).
checkReservedTree :: RawFilePath -> Int -> ByteString -> IO ()
checkReservedTree path depth logicalName = do
  when (depth > 1024) (caError "CA tree nesting exceeds limit")
  status <- Files.getSymbolicLinkStatus path
  let name = if depth == 0 && not (B.null logicalName) then logicalName else baseName path
  either caError pure (checkReserved path name)
  if Files.isDirectory status
    then do
      entries <- directoryEntries path
      forM_ entries $ \entry -> checkReservedTree (path <> "/" <> entry) (depth + 1) ""
    else if Files.isRegularFile status
      then checkReservedFile path
      else if Files.isSymbolicLink status
        then do
          target <- Files.readSymbolicLink path
          either caError pure (checkReserved path target)
        else caError ("unsupported CA output file `" ++ C.unpack path ++ "'")

-- | Rewrite a regular file in bounded chunks, retaining enough tail to catch
-- matches (including UTF-32LE encodings) across read boundaries; restore the
-- mode and mtime=1 (C++ rewriteRegularFile).
rewriteRegularFile :: RawFilePath -> ByteString -> ByteString -> FileMode -> IO ()
rewriteRegularFile path from to mode = do
  Files.setFileMode path 0o600
  let temporary = path <> ".goonix-rewrite"
  exists <- Files.fileExist temporary
  when exists (caError ("CA temporary file `" ++ C.unpack temporary ++ "' already exists"))
  let keep = B.length from * 4 - 1
      process pending =
        let count = if B.length pending > keep then B.length pending - keep else 0
            -- A prefix of FROM at the end is a potential whole match crossing
            -- the next read, not an opaque fragment at this boundary.
            adjusted = adjust count
            adjust n = head ([n - len | len <- [min n (B.length from - 1), min n (B.length from - 1) - 1 .. 1],
                              B.drop (n - len) (B.take n pending) == B.take len from] ++ [n])
        in adjusted
      rewrite part = either caError pure (replaceWhole part from to path True)
      -- C++ AutoDelete cleanup(temporary, false): remove the temporary on any
      -- failure (cancelled only after the rename succeeds), so a rejected
      -- output does not leave a .goonix-rewrite that poisons the next build.
      removeTemporary = do
        present <- Files.fileExist temporary
        when present (Files.removeLink temporary)
  (bracket (openBinaryFile (C.unpack path) ReadMode) (hClose) $ \input ->
    bracket (openBinaryFile (C.unpack temporary) WriteMode) (\output -> hClose output) $ \output -> do
      let loop pending = do
            chunk <- B.hGetSome input (128 * 1024)
            if B.null chunk
              then rewrite pending >>= B.hPut output
              else do
                let combined = pending <> chunk
                    count = process combined
                rewrite (B.take count combined) >>= B.hPut output
                loop (B.drop count combined)
      loop B.empty)
    `onException` removeTemporary
  Files.setFileMode temporary mode
  restoreMtime temporary False
  Files.rename temporary path

-- | Rewrite every occurrence of a token hash in a tree: file contents, entry
-- names, symlink targets; modes and timestamps restored (C++ rewriteTree).
rewriteTree :: RawFilePath -> ByteString -> ByteString -> IO ()
rewriteTree path from to = go path 0 True
  where
    go current depth outputRoot = do
      when (depth > 1024) (caError "CA tree nesting exceeds limit")
      status <- Files.getSymbolicLinkStatus current
      if Files.isDirectory status
        then do
          let originalMode = Files.fileMode status .&. 0o7777
          Files.setFileMode current 0o700
          (do
            entries <- directoryEntries current
            forM_ entries $ \entry -> go (current <> "/" <> entry) (depth + 1) False
            forM_ entries $ \entry -> do
              name <- either caError pure (replaceWhole entry from to (current <> "/" <> entry) True)
              when (name /= entry) $ do
                when (B.null name || name == "." || name == ".." || B.elem 47 name)
                  (caError ("invalid CA file name in `" ++ C.unpack current ++ "'"))
                Files.rename (current <> "/" <> entry) (current <> "/" <> name)
            restoreMtime current False
            Files.setFileMode current originalMode)
            `catch` (\(exception :: SomeException) -> Files.setFileMode current originalMode >> throwIO exception)
        else if Files.isRegularFile status
          then do
            let mode = (Files.fileMode status .&. 0o170000) .|. (if Files.fileMode status .&. 0o100 /= 0 then 0o555 else 0o444)
            rewriteRegularFile current from to mode
          else if Files.isSymbolicLink status
            then do
              target <- Files.readSymbolicLink current
              target' <- either caError pure (replaceWhole target from to current True)
              when (target' /= target) $ do
                let parentPath0 = C.dropWhileEnd (/= '/') current
                    parentPath = if B.null parentPath0 then "." else B.init parentPath0
                    insideOutput = not outputRoot
                parentStatus <- Files.getSymbolicLinkStatus parentPath
                when insideOutput (Files.setFileMode parentPath 0o700)
                (do
                  let replacement = current <> ".goonix-new-link"
                  replacementExists <- Files.fileExist replacement
                  when replacementExists (caError ("CA temporary symlink `" ++ C.unpack replacement ++ "' already exists"))
                  Files.createSymbolicLink target' replacement
                  Files.rename replacement current
                  restoreMtime current True
                  Files.setFileMode parentPath (Files.fileMode parentStatus .&. 0o7777))
                  `catch` (\(exception :: SomeException) ->
                    Files.setFileMode parentPath (Files.fileMode parentStatus .&. 0o7777) >> throwIO exception)
            else caError ("unsupported CA output file `" ++ C.unpack current ++ "'")

-- | The inverse mapping: rewrite the final hash back to the token (and the
-- siblings' final hashes back to their tokens, in reverse order) and hash the
-- result as a tree, WITHOUT writing anything (C++ inverseTree).
inverseTree :: RawFilePath -> ByteString -> ByteString -> Map.Map ByteString ByteString -> IO ByteString
inverseTree path final token siblings = go path 0
  where
    inverse value =
      let step current (siblingToken, siblingFinal) =
            either error id (replaceWhole current (hashPart siblingFinal) (hashPart siblingToken) path False)
      in foldl step (either error id (replaceWhole value final token path False)) (Map.toDescList siblings)
    go current depth = do
      when (depth > 1024) (caError "CA tree nesting exceeds 1024 directories")
      status <- Files.getSymbolicLinkStatus current
      if Files.isRegularFile status
        then do
          sink <- newHashSink SHA256
          let executable = if Files.fileMode status .&. 0o100 /= 0 then 1 else 0
          updateHashSink sink (treeDomain <> B.pack [1, executable] <> put64 (fromIntegral (Files.fileSize status)))
          withBinaryFile (C.unpack current) ReadMode $ \handle ->
            let keep = B.length final - 1
                loop pending = do
                  chunk <- B.hGetSome handle (128 * 1024)
                  if B.null chunk
                    then updateHashSink sink (inverse pending)
                    else do
                      let combined = pending <> chunk
                          count0 = if B.length combined > keep then B.length combined - keep else 0
                          count = head ([count0 - len | len <- [min count0 (B.length final - 1), min count0 (B.length final - 1) - 1 .. 1],
                                         B.drop (count0 - len) (B.take count0 combined) == B.take len final] ++ [count0])
                      updateHashSink sink (inverse (B.take count combined))
                      loop (B.drop count combined)
            in loop B.empty
          printHash <$> finishHashSink sink
        else if Files.isSymbolicLink status
          then do
            target <- Files.readSymbolicLink current
            pure (printHash (Hash SHA256 (sha256 (treeDomain <> B.pack [2] <> putBytes (inverse target)))))
          else if Files.isDirectory status
            then do
              entries <- directoryEntries current
              let ordered = sortBy (\a b -> compare (inverse a) (inverse b)) entries
              parts <- forM ordered $ \entry -> do
                child <- go (current <> "/" <> entry) (depth + 1)
                pure (putBytes (inverse entry) <> putBytes child)
              pure (printHash (Hash SHA256 (sha256 (treeDomain <> B.pack [3]
                <> put64 (fromIntegral (length ordered)) <> B.concat parts))))
            else caError ("unsupported file type in CA tree `" ++ C.unpack current ++ "'")

printHash :: Hash -> ByteString
printHash = encodeBase16 . hashDigest
  where
    encodeBase16 = B.concatMap (\w -> B.pack [hexChar (w `div` 16), hexChar (w `mod` 16)])
    hexChar n = if n < 10 then 48 + n else 87 + n

-- | C++ sameContent: the inverse tree hashes to the expected tree hash.
sameContent :: RawFilePath -> ByteString -> ByteString -> Hash -> Map.Map ByteString ByteString -> IO Bool
sameContent path final token expected siblings = do
  inverse <- inverseTree path (hashPart final) (hashPart token) siblings
  pure (inverse == printHash expected)

-- | A strict store path: the store prefix, a 32-character base32 hash part
-- (NOT the reserved alphabet), '-', a nonempty name (C++ isStorePathStrict).
isStorePathStrict :: ByteString -> ByteString -> Bool
isStorePathStrict store path =
  B.length path > B.length store + 1
  && B.take (B.length store + 1) path == store <> "/"
  && let basename = B.drop (B.length store + 1) path
         hash = B.take 32 basename
     in B.length basename >= 34 && B.index basename 32 == 45
        && B.all (`B.elem` base32Alphabet) hash
        && either (const False) (const True) (validateStoreName (B.drop 33 basename))

-- | C++ checkResolvedDerivation: marked resolved, no floating inputs, outputs
-- are tokens (content) or strict paths (resolved/fixed), environment agrees,
-- and no placeholder survives anywhere.
checkResolvedDerivation :: ByteString -> Derivation -> Either String ()
checkResolvedDerivation store drv = do
  unless (resolvedDerivation (Map.lookup "goonixResolved" (environment drv)))
    (Left "goonix: derivation is not marked resolved")
  unless (Map.null (inputDrvs drv)) (Left "goonix: resolved derivation still has floating inputs")
  addressing <- addressingOf (Map.lookup "goonixAddressing" (environment drv))
  forM_ (Map.toList (outputs drv)) $ \(output, out) -> do
    let path = outputPath out
        fixed = not (B.null (outputHash out))
    if fixed
      then unless (isStorePathStrict store path) (Left ("goonix: invalid fixed output `" ++ C.unpack path ++ "'"))
      else case addressing of
        Content -> unless (isTokenStorePath store path)
          (Left ("goonix: content output `" ++ C.unpack path ++ "' is not a self token"))
        Resolved -> unless (isStorePathStrict store path)
          (Left ("goonix: resolved output `" ++ C.unpack path ++ "' is not a final store path"))
        Input -> Left "goonix: resolved derivation has input addressing"
    case Map.lookup output (environment drv) of
      Just value | value /= path ->
        Left ("goonix: resolved output `" ++ C.unpack output ++ "' disagrees with its environment")
      _ -> Right ()
  let scan value = go value 0
        where
          prefix = store <> "/"
          go current at = case breakOn prefix (B.drop at current) of
            (_, rest) | B.null rest -> Right ()
            (before, _) ->
              let start = at + B.length before
                  end = start + B.length prefix + B.length (B.takeWhile (\c -> c `notElem` [47, 34, 39, 32, 10, 9, 41, 40, 44]) (B.drop (start + B.length prefix) current))
                  candidate = B.take (end - start) (B.drop start current)
              in if isPlaceholderPath store candidate
                then Left ("goonix: unresolved placeholder `" ++ C.unpack candidate ++ "' in resolved derivation")
                else go current end
  scan (builder drv)
  forM_ (args drv) scan
  forM_ (Map.elems (environment drv)) scan

-- | C++ checkInputAddressedPolicy: an input-addressed derivation may not depend
-- on a content/resolved-addressed one.  `load' reads an input derivation; an
-- absent input is left to the normal validity machinery (Nothing).
checkInputAddressedPolicy :: Derivation -> (ByteString -> IO (Maybe Derivation)) -> IO ()
checkInputAddressedPolicy drv load = do
  when (goonixAddressed (Map.lookup "goonixAddressing" (environment drv))) (pure ())
  unless (goonixAddressed (Map.lookup "goonixAddressing" (environment drv))) $
    forM_ (Map.keys (inputDrvs drv)) $ \input -> do
      loaded <- load input
      forM_ loaded $ \inDrv ->
        when (goonixAddressed (Map.lookup "goonixAddressing" (environment inDrv))) $
          caError ("input-addressed derivation depends on content/resolved-addressed `"
            ++ C.unpack input ++ "'; mark the dependent as content-addressed too (goonix mixed policy)")

-- | C++ resolveDerivation: the realised callback chooses each input output's
-- path; placeholders are substituted in builder/args/env; content outputs stay
-- at token paths, resolved outputs get resolvedAddressedPath over the canonical
-- bytes without goonixResolved, then the marker is set and the env synced.
resolveDerivation :: ByteString -> ByteString -> Derivation
  -> (ByteString -> Derivation -> ByteString -> IO ByteString)
  -> IO Derivation
resolveDerivation store unresolvedPath unresolved realised = do
  replacementLists <- forM (Map.toList (inputDrvs unresolved)) $ \(input, outs) ->
    forM (Set.toList outs) $ \output -> do
      inDrv <- loadDerivation input
      case Map.lookup output (outputs inDrv) of
        Nothing -> caError ("derivation has no output `" ++ C.unpack output ++ "'")
        Just out -> do
          chosen <- realised input inDrv output
          pure (outputPath out, chosen)
  let replacements = Map.fromList (concat replacementLists)
      chosenPaths = Map.elems replacements
      substitute value = Map.foldlWithKey' (\current from to -> replaceAll from to current) value replacements
      replaceAll from to = go
        where
          go current = case breakOn from current of
            (before, rest) | B.null rest -> current
                           | otherwise -> before <> to <> go (B.drop (B.length from) rest)
      substituted = unresolved
        { builder = substitute (builder unresolved)
        , args = map substitute (args unresolved)
        , environment = Map.map substitute (environment unresolved)
        , inputSrcs = Set.union (inputSrcs unresolved) (Set.fromList chosenPaths)
        , inputDrvs = Map.empty
        }
      -- Content outputs stay at their token paths; placeholders removed.
      tokenised = substituted
        { outputs = Map.mapWithKey (\output out ->
            if not (B.null (outputHash out)) then out
            else out { outputPath = tokenPath store output (storePathToName store (outputPath out)) })
            (outputs substituted)
        }
      syncEnv drv' = drv' { environment = foldl (\env (output, out) -> Map.insert output (outputPath out) env)
                              (environment drv') (Map.toList (outputs drv')) }
      withoutMarker = syncEnv (tokenised { environment = Map.delete "goonixResolved" (environment tokenised) })
      pathBytes = writeDerivation withoutMarker
      marked = withoutMarker { environment = Map.insert "goonixResolved" "1" (environment withoutMarker) }
      addressing = addressingOf (Map.lookup "goonixAddressing" (environment unresolved))
  resolvedOutputs <- case addressing of
    Right Resolved -> forM (Map.toList (outputs marked)) $ \(output, out) ->
      if not (B.null (outputHash out))
        then pure (output, out)
        else do
          let name = storePathToName store (outputPath (outputs unresolved Map.! output))
          pure (output, out { outputPath = resolvedAddressedPath store output name pathBytes })
    _ -> pure (Map.toList (outputs marked))
  let resolved = syncEnv (marked { outputs = Map.fromList resolvedOutputs })
  either caError pure (checkResolvedDerivation store resolved)
  pure resolved
  where
    loadDerivation path = do
      bytes <- B.readFile (C.unpack path)
      either caError pure (parseDerivation bytes)

-- | C++ contentOutputOrder: an output referring to a sibling's token is
-- finalised after that sibling; cycles are refused.
contentOutputOrder :: Derivation -> [RawFilePath] -> RawFilePath -> IO [(ByteString, ByteString)]
contentOutputOrder drv allPaths chrootRoot = do
  let outputPaths = Map.fromList [(outputPath out, output) | (output, out) <- Map.toList (outputs drv)]
  (_, _, order) <- foldM (visit outputPaths) (Set.empty, Set.empty, []) (map outputPath (Map.elems (outputs drv)))
  pure (reverse order)
  where
    visit outputPaths (visiting, done, order) path
      | Set.member path done = pure (visiting, done, order)
      | Set.member path visiting = caError "cycle between content-addressed sibling outputs"
      | otherwise = do
          let physical = chrootRoot <> path
          (references, _) <- scanReferences physical allPaths
          (visiting', done', order') <- foldM (visit outputPaths)
            (Set.insert path visiting, done, order)
            [sibling | (sibling, _) <- Map.toList outputPaths, sibling /= path, Set.member sibling references]
          pure (Set.delete path visiting', Set.insert path done', (outputPaths Map.! path, path) : order')

-- | The result of finalising one content output.
data Finalised = Finalised
  { finalPath :: !ByteString
  , finalReferences :: ![ByteString]
  , finalNarHash :: !Hash
  , finalNarSize :: !Word64
  , finalCreated :: !Bool
  }

-- | C++ finaliseContentOutput: check the reserved tree, rewrite sibling tokens,
-- scan references, tree-hash, compute the content address, root it, reuse an
-- identical existing item or refuse a collision, rewrite the self token, rename,
-- verify the inverse mapping, and return the final path with its NAR facts.
finaliseContentOutput :: ByteString -> ByteString -> ByteString -> ByteString
  -> [RawFilePath] -> Map.Map ByteString ByteString -> RawFilePath
  -> (ByteString -> IO ()) -> IO Finalised
finaliseContentOutput store token output name allPaths finalOutputs actualTokenPath addTempRoot = do
  let physical = if B.null actualTokenPath then token else actualTokenPath
      referencePaths0 = allPaths ++ Map.elems finalOutputs
  checkReservedTree physical 0 (baseName token)
  forM_ (Map.toList finalOutputs) $ \(siblingToken, siblingFinal) ->
    when (siblingToken /= token) $
      rewriteTree physical (hashPart siblingToken) (hashPart siblingFinal)
  (initialReferences, _) <- scanReferences physical referencePaths0
  built <- treeHash physical
  let namingReferences = Set.delete token initialReferences
      final = contentAddressedPath store output name built (Set.toList namingReferences)
  addTempRoot final
  let referencePaths = final : referencePaths0
      oldHash = hashPart token
      newHash = hashPart final
      siblings = Map.delete token finalOutputs
      scanAndHash path = do
        (references, _) <- scanReferences path referencePaths
        nar <- hashNar path
        size <- fromIntegral . B.length <$> dumpNar path
        pure (Set.toList references, nar, size)
      reuseExisting = do
        same <- sameContent final final token built siblings
        unless same (caError ("CA content address collision at `" ++ C.unpack final ++ "': existing item differs"))
        deleteTree physical
        (references, nar, size) <- scanAndHash final
        pure (Finalised final references nar size False)
  exists <- Files.fileExist final
  if exists
    then reuseExisting
    else do
      rewriteTree physical oldHash newHash
      Files.rename physical final
      good <- sameContent final final token built siblings
      unless good (deleteTree final >> caError ("CA inverse mapping failed for `" ++ C.unpack final ++ "'"))
      (references, nar, size) <- scanAndHash final
      pure (Finalised final references nar size True)

-- | C++ removeGoonixEnvironment: goonix* and __files/__file:* are daemon
-- metadata, never builder environment.
removeGoonixEnvironment :: Map.Map ByteString ByteString -> Map.Map ByteString ByteString
removeGoonixEnvironment = Map.filterWithKey $ \key _ ->
  not ("goonix" `B.isPrefixOf` key || key == "__files" || "__file:" `B.isPrefixOf` key)

-- | C++ materialiseGoonixFiles: write the embedded builder files into the build
-- directory and point $NIX_BUILD_TOP/<name> arguments at them.
materialiseGoonixFiles :: Derivation -> [ByteString] -> RawFilePath -> RawFilePath -> IO [ByteString]
materialiseGoonixFiles drv arguments hostDirectory sandboxDirectory =
  case Map.lookup "__files" (environment drv) of
    Nothing -> pure arguments
    Just embedded -> foldM materialise arguments (C.words embedded)
  where
    materialise current name = do
      when (B.null name || B.index name 0 == 47 || B.elem 92 name)
        (caError ("invalid embedded builder file `" ++ C.unpack name ++ "'"))
      forM_ (C.split '/' name) $ \component ->
        when (B.null component || component == "." || component == "..")
          (caError ("invalid embedded builder file `" ++ C.unpack name ++ "'"))
      value <- case Map.lookup ("__file:" <> name) (environment drv) of
        Just v -> pure v
        Nothing -> caError ("missing embedded builder file `" ++ C.unpack name ++ "'")
      let file = hostDirectory <> "/" <> name
          sandboxFile = sandboxDirectory <> "/" <> name
          current' = map (\arg -> if arg == "$NIX_BUILD_TOP/" <> name then sandboxFile else arg) current
          directory = C.dropWhileEnd (/= '/') file
      unless (B.null directory) (mkdirParents (B.init directory))
      B.writeFile (C.unpack file) value
      pure current'