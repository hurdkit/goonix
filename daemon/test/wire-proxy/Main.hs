{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Primitive wire vectors and black-box tests over real Unix sockets.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, SomeException, bracket, catch, finally, throwIO, try)
import GHC.IO.Exception (IOErrorType (EOF), ioe_type)
import Control.Monad (forM, forM_, unless, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Goonix.Store.Wire
import Network.Socket (Family (AF_UNIX), SockAddr (SockAddrUnix), Socket, SocketType (Stream), accept, bind, close, connect, listen, shutdown, ShutdownCmd (ShutdownSend), socket, unsafeFdSocket, withSocketsDo)
import Network.Socket.ByteString (recv, sendAll)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess), exitFailure)
import System.Posix.ByteString (RawFilePath)
import System.Posix.Directory.ByteString (getWorkingDirectory)
import System.Posix.Env.ByteString (getArgs)
import System.Posix.Files.ByteString (removeLink)
import GHC.Conc (threadWaitRead, threadWaitWrite)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags)
import System.Posix.IO.ByteString (fdRead, openFd)
import System.Posix.Types (Fd (..))
import System.Process (ProcessHandle, proc, withCreateProcess, terminateProcess, waitForProcess)
import System.Process (readProcess)

main :: IO ()
main = do
  args <- getArgs
  proxy <- case args of
    [path] -> pure path
    _ -> do
      B.putStr "usage: wire-proxy-test PROXY\n"
      exitFailure
  checkPrimitives
  checkCodec
  cwd <- getWorkingDirectory
  let root = cwd <> "/test/wire-proxy/.build/run"
  recreateDirectory root
  withSocketsDo $ socketTests proxy root
  B.putStr "wire proxy checks passed\n"

checkPrimitives :: IO ()
checkPrimitives = do
  assert "int vector" (B.unpack (encodeInt 0x78563412) == [0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0])
  assert "int round trip" (decodeInt (encodeInt maxBound) == Right maxBound)
  assert "bool" (decodeBool (encodeInt 2) == Right True)
  assert "u64" (decodeWord64 (encodeWord64 0x8877665544332211) == Right 0x8877665544332211)
  let values = [B.empty, B.pack [0, 255, 10], "abcdefgh", "abcdefghi"]
      bytes = encodeStrings values
  assert "strings" (decodeStrings bytes == Right values)
  assert "pairs" (decodeStringPairs (encodeStringPairs [("a", "b\0"), ("", "c")])
    == Right [("a", "b\0"), ("", "c")])
  let nonzeroUpper = B.pack [1, 0, 0, 0, 0, 0, 0, 1]
      nonzeroPad = encodeString "x"
  assert "upper word" (decodeInt nonzeroUpper == Left "implementation cannot deal with > 32-bit integers")
  assert "padding" (decodeString (B.init nonzeroPad <> B.singleton 1) == Left "non-zero padding")
  assert "truncated int" (decodeInt (B.take 7 nonzeroUpper) == Left "unexpected end of input")
  assert "truncated string" (decodeString (encodeInt 4 <> "ab") == Left "unexpected end of input")
  assert "all operations" (map operationCode operations == expectedCodes)
  assert "unique operations" (length [() | op <- operations, op' <- operations, operationName op == operationName op', operationCode op /= operationCode op'] == 0)
  where
    expectedCodes = [1,3,4,5,6,7,8,9,10,11,12,13,14,16,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,80,81]

checkCodec :: IO ()
checkCodec = do
  let helloC = encodeInt workerMagic1 <> encodeInt protocolVersion <> encodeInt 0 <> encodeInt 1
      helloS = encodeInt workerMagic2 <> encodeInt protocolVersion <> encodeInt stderrLast
      request = encodeInt 1 <> encodeString (B.pack [0, 255, 10])
      reply = encodeInt stderrNext <> encodeString (B.pack [0, 10, 255]) <> encodeInt stderrLast <> encodeInt 1
      (s1, f1) = feedBytes ClientToDaemon newConnection helloC
      (s2, f2) = feedBytes DaemonToClient s1 helloS
      (s3, f3) = feedBytes ClientToDaemon s2 request
      (s4, f4) = feedBytes DaemonToClient s3 reply
      allFrames = f1 <> f2 <> f3 <> f4
  assert "handshake fields" (handshakeClientVersion (connectionHandshake s4) == Just protocolVersion)
  assert "parsed handshake" (map frameHeader f1 == ["handshake client-magic", "handshake client-version", "handshake affinity", "handshake reserve-space"])
  assert "operation" (map frameHeader f3 == ["operation", "request wopIsValidPath path"])
  assert "stderr" (map frameHeader f4 == ["stderr", "STDERR_NEXT", "stderr", "reply wopIsValidPath result"])
  assert "raw fidelity" (map frameBytes allFrames == [encodeInt workerMagic1, encodeInt protocolVersion, encodeInt 0, encodeInt 1, encodeInt workerMagic2, encodeInt protocolVersion, encodeInt stderrLast, encodeInt 1, encodeString (B.pack [0,255,10]), encodeInt stderrNext, encodeString (B.pack [0,10,255]), encodeInt stderrLast, encodeInt 1])
  checkSplitCodec
  checkNar
  checkImport
  let (badState, badFrames) = feedBytes ClientToDaemon newConnection (B.pack [1,0,0,0,1,0,0,0])
      (_, badFrames') = feedBytes ClientToDaemon badState (B.pack [255,0])
  assert "bad upper word recorded" (map frameHeader badFrames == ["parse-error 696d706c656d656e746174696f6e2063616e6e6f74206465616c2077697468203e2033322d62697420696e746567657273"])
  assert "bad bytes retained" (B.concat (map frameBytes (badFrames <> badFrames')) == B.pack [1,0,0,0,1,0,0,0,255,0])
  let (truncated, beforeEof) = feedBytes ClientToDaemon newConnection (B.take 3 (encodeInt workerMagic1))
      (_, afterEof) = endOfStream ClientToDaemon truncated
  assert "partial at eof" (null beforeEof && map frameBytes afterEof == [B.take 3 (encodeInt workerMagic1)])
  let (_, opaqueFrames) = feedBytes ClientToDaemon badState (B.pack [0, 127, 255])
  assert "opaque bytes" (B.concat (map frameBytes opaqueFrames) == B.pack [0,127,255])

checkSplitCodec :: IO ()
checkSplitCodec = do
  let c = encodeInt workerMagic1 <> encodeInt protocolVersion <> encodeInt 0 <> encodeInt 1 <> encodeInt 1 <> encodeString "split"
      s = encodeInt workerMagic2 <> encodeInt protocolVersion <> encodeInt stderrLast <> encodeInt stderrLast <> encodeInt 1
      (clientState, clientFrames) = feedIn ClientToDaemon newConnection (chunks 1 c)
      (_, serverFrames) = feedIn DaemonToClient clientState (chunks 3 s)
  assert "split raw" (B.concat (map frameBytes clientFrames) == c && B.concat (map frameBytes serverFrames) == s)
  assert "split fields" (map frameHeader clientFrames == ["handshake client-magic", "handshake client-version", "handshake affinity", "handshake reserve-space", "operation", "request wopIsValidPath path"])
  assert "split reply" (map frameHeader serverFrames == ["handshake server-magic", "handshake server-version", "handshake stderr", "stderr", "reply wopIsValidPath result"])

checkNar :: IO ()
checkNar = do
  let regular = foldMap encodeString ["nix-archive-1", "(", "type", "regular", "executable", "", "contents"]
        <> encodeWord64 10 <> "abc\0\255defgh" <> B.replicate 6 0 <> encodeString ")"
      request = encodeInt 7 <> encodeString "file" <> encodeInt 1 <> encodeInt 1 <> encodeString "sha256" <> regular <> encodeInt 13
      (_, frames) = feedIn ClientToDaemon newConnection (chunks 5 (handshakeC <> request))
  assert "nar followed by operation" (length (filter (== "operation") (map frameHeader frames)) == 2 && any (== "nar contents") (map frameHeader frames) && last (map frameHeader frames) == "operation")
  assert "nar bytes" (B.concat (map frameBytes frames) == handshakeC <> request)
  let (singleState, _) = feedIn ClientToDaemon newConnection [handshakeC <> encodeInt 7 <> encodeString "file" <> encodeInt 1 <> encodeInt 1 <> encodeString "sha256" <> regular]
      (_, response) = feedIn DaemonToClient singleState [handshakeS <> encodeInt stderrLast <> encodeString "stored"]
  assert "nar response" (map frameHeader response == ["handshake server-magic", "handshake server-version", "handshake stderr", "stderr", "reply wopAddToStore path"])

checkImport :: IO ()
checkImport = do
  let (s1, _) = feedIn ClientToDaemon newConnection [handshakeC <> encodeInt 27]
      (s2, _) = feedIn DaemonToClient s1 [handshakeS <> encodeInt stderrRead <> encodeInt 4]
      (s3, f3) = feedIn ClientToDaemon s2 [encodeString "abcd"]
      (s4, f4) = feedIn DaemonToClient s3 [encodeInt stderrRead <> encodeInt 3]
      (s5, _) = feedIn ClientToDaemon s4 [encodeString "xyz"]
      (_, f6) = feedIn DaemonToClient s5 [encodeInt stderrNext <> encodeString "log" <> encodeInt stderrLast <> encodeStrings ["p"]]
  assert "read data" (map frameHeader f3 == ["stderr-read-data"])
  assert "read twice" (map frameHeader f4 == ["stderr", "STDERR_READ"])
  assert "import end" (map frameHeader f6 == ["stderr", "STDERR_NEXT", "stderr", "reply wopImportPaths paths.count", "reply wopImportPaths paths.item"])

handshakeC, handshakeS :: ByteString
handshakeC = encodeInt workerMagic1 <> encodeInt protocolVersion <> encodeInt 0 <> encodeInt 1
handshakeS = encodeInt workerMagic2 <> encodeInt protocolVersion <> encodeInt stderrLast

feedIn :: Direction -> ConnectionState -> [ByteString] -> (ConnectionState, [Frame])
feedIn direction state input = go state input []
  where
    go s [] acc = (s, reverse acc)
    go s (chunk : rest) acc = let (s', frames) = feedBytes direction s chunk in go s' rest (reverse frames ++ acc)

chunks :: Int -> ByteString -> [ByteString]
chunks n bytes
  | B.null bytes = []
  | otherwise = B.take n bytes : chunks n (B.drop n bytes)

socketTests :: RawFilePath -> RawFilePath -> IO ()
socketTests proxy root = do
  let upstream = root <> "/upstream"
      downstream = root <> "/downstream"
      transcript = root <> "/transcript"
  withServer upstream $ \listener -> do
    withProxy proxy upstream downstream transcript $ \handle -> do
      client <- connectWait downstream
      server <- acceptBlocking listener
      let helloC' = encodeInt workerMagic1
          helloS' = encodeInt workerMagic2 <> encodeInt protocolVersion
      sendBytes client helloC'
      receivedMagic <- receiveExactly server 8
      assert "upstream magic" (receivedMagic == helloC')
      sendBytes server helloS'
      receivedGreeting <- receiveExactly client 16
      assert "downstream greeting" (receivedGreeting == helloS')
      let restC = encodeInt protocolVersion <> encodeInt 0 <> encodeInt 1 <> encodeInt 1 <> encodeString (B.pack [0,255,10,13])
          restS = encodeInt stderrLast <> encodeInt stderrNext <> encodeString (B.pack [0,10,255]) <> encodeInt stderrLast <> encodeInt 1
      sendSplit client restC
      receivedRequest <- receiveExactly server (B.length restC)
      assert "upstream request" (receivedRequest == restC)
      sendSplit server restS
      receivedReply <- receiveExactly client (B.length restS)
      assert "downstream reply" (receivedReply == restS)
      let arbitrary = B.pack (take 32771 (cycle [0..255]))
      sent <- concurrently (sendBytes client arbitrary) (receiveExactly server (B.length arbitrary))
      assert "arbitrary upstream" (sent == arbitrary)
      shutdown client ShutdownSend
      receivedEof <- receiveExactly server 1
      assert "client half close" (receivedEof == B.empty)
      sentAfter <- concurrently (sendBytes server arbitrary) (receiveExactly client (B.length arbitrary))
      assert "upstream after half close" (sentAfter == arbitrary)
      close client
      close server
      terminateProcess handle
      status <- waitForProcess handle
      assert "clean sigterm" (status == ExitSuccess)
      bytes <- readBytes transcript
      assert "transcript raw bytes" (recoverDirection "1 c2s" bytes == helloC' <> restC <> arbitrary)
      assert "reverse raw bytes" (recoverDirection "1 s2c" bytes == helloS' <> restS <> arbitrary)
      assert "transcript handshake" (C.isInfixOf "handshake client-magic" bytes)
      assert "transcript operation" (C.isInfixOf "operation" bytes)
      assert "transcript opaque" (C.isInfixOf "unframed" bytes)
  abruptTests proxy root
  concurrentTests proxy root

abruptTests :: RawFilePath -> RawFilePath -> IO ()
abruptTests proxy root = do
  let upstream = root <> "/abrupt-upstream"
      downstream = root <> "/abrupt-downstream"
      transcript = root <> "/abrupt-transcript"
  withServer upstream $ \listener -> do
    withProxy proxy upstream downstream transcript $ \handle -> do
      client <- connectWait downstream
      server <- acceptBlocking listener
      let input = B.pack (take 20000 (cycle [255, 0, 128, 1]))
      received <- concurrently (sendBytes client input) (receiveExactly server (B.length input))
      assert "before abrupt close" (received == input)
      close server
      close client
      terminateProcess handle
      abruptStatus <- waitForProcess handle
      assert "abrupt clean sigterm" (abruptStatus == ExitSuccess)
      bytes <- readBytes transcript
      assert "abrupt raw retained" (recoverDirection "1 c2s" bytes == input)

-- Exercise two clients while one direction has a full socket buffer.  This
-- catches accidentally serialising accept or relay work in the proxy.
concurrentTests :: RawFilePath -> RawFilePath -> IO ()
concurrentTests proxy root = do
  let upstream = root <> "/concurrent-upstream"
      downstream = root <> "/concurrent-downstream"
      transcript = root <> "/concurrent-transcript"
  withServer upstream $ \listener -> withProxy proxy upstream downstream transcript $ \handle -> do
    results <- forM [1..4 :: Int] $ \_ -> do
      done <- newEmptyMVar
      _ <- forkIO $ (do
        client <- connectWait downstream
        server <- acceptBlocking listener
        let payload = B.pack (take 100000 (cycle [0..255]))
        received <- concurrently (sendBytes client payload) (receiveExactly server (B.length payload))
        echoed <- concurrently (sendBytes server payload) (receiveExactly client (B.length payload))
        close client
        close server
        putMVar done (received == payload && echoed == payload))
          `catch` \e -> putMVar done False >> throwIO (e :: SomeException)
      pure done
    forM_ results $ \result -> takeMVar result >>= assert "concurrent client"
    terminateProcess handle
    status <- waitForProcess handle
    assert "concurrent clean sigterm" (status == ExitSuccess)

concurrently :: IO () -> IO a -> IO a
concurrently writer reader = do
  done <- newEmptyMVar
  _ <- forkIO (writer `finally` putMVar done ())
  answer <- reader
  takeMVar done
  pure answer

withServer :: RawFilePath -> (Socket -> IO a) -> IO a
withServer path action = bracket (listenSocket path) (\fd -> close fd `finally` removeIfPresent path) action

withProxy :: RawFilePath -> RawFilePath -> RawFilePath -> RawFilePath -> (ProcessHandle -> IO a) -> IO a
withProxy proxy upstream downstream transcript action =
  withCreateProcess (proc (C.unpack proxy) (map C.unpack [upstream, downstream, transcript]))
    (\_ _ _ handle -> action handle)

listenSocket :: RawFilePath -> IO Socket
listenSocket path = do
  fd <- socket AF_UNIX Stream 0
  bind fd (SockAddrUnix (C.unpack path))
  listen fd 16
  pure fd

connectWait :: RawFilePath -> IO Socket
connectWait path = attempt (0 :: Int)
  where
    attempt n = do
      result <- try (connectSocket path)
      case result of
        Right fd -> pure fd
        Left e | n >= 100 -> throwIO (e :: IOException)
               | otherwise -> threadDelay 10000 >> attempt (n + 1)

connectSocket :: RawFilePath -> IO Socket
connectSocket path = do
  fd <- socket AF_UNIX Stream 0
  connect fd (SockAddrUnix (C.unpack path))
  pure fd

acceptBlocking :: Socket -> IO Socket
acceptBlocking listener = do
  waitSocket listener threadWaitRead
  fst <$> accept listener

waitSocket :: Socket -> (Fd -> IO ()) -> IO ()
waitSocket fd wait = unsafeFdSocket fd >>= wait . Fd

sendBytes :: Socket -> ByteString -> IO ()
sendBytes fd bytes = waitSocket fd threadWaitWrite >> sendAll fd bytes

sendSplit :: Socket -> ByteString -> IO ()
sendSplit fd bytes = forM_ (chunks 3 bytes) $ \chunk -> sendBytes fd chunk >> threadDelay 100

receiveExactly :: Socket -> Int -> IO ByteString
receiveExactly fd wanted = go B.empty
  where
    go acc
      | B.length acc >= wanted = pure acc
      | otherwise = do
          waitSocket fd threadWaitRead
          bytes <- recv fd (wanted - B.length acc)
          if B.null bytes then pure acc else go (acc <> bytes)

readBytes :: RawFilePath -> IO ByteString
readBytes path = do
  compressed <- lookupEnv "GOONIX_WIRE_GZIP"
  if compressed == Just "1"
    then C.pack <$> readProcess "gzip" ["-dc", C.unpack path] ""
    else bracket (openFd path ReadOnly defaultFileFlags) closeFd (readAllFd B.empty)

readAllFd :: ByteString -> Fd -> IO ByteString
readAllFd acc fd = do
  result <- try (fdRead fd 32768)
  case result of
    Left e | ioe_type e == EOF -> pure acc
           | otherwise -> throwIO (e :: IOException)
    Right bytes | B.null bytes -> pure acc
                | otherwise -> readAllFd (acc <> bytes) fd

recoverDirection :: ByteString -> ByteString -> ByteString
recoverDirection direction transcript = B.concat (go False (C.lines transcript))
  where
    go _ [] = []
    go selected (line : rest)
      | "  raw " `B.isPrefixOf` line =
          (if selected then [hexDecode (B.drop 6 line)] else []) ++ go False rest
      | B.isPrefixOf "  " line = go selected rest
      | otherwise = go (B.isPrefixOf (direction <> " ") line) rest

hexDecode :: ByteString -> ByteString
hexDecode bytes
  | B.null bytes = B.empty
  | otherwise = B.singleton (digit (B.index bytes 0) * 16 + digit (B.index bytes 1)) <> hexDecode (B.drop 2 bytes)
  where
    digit b
      | b >= 48 && b <= 57 = b - 48
      | b >= 97 && b <= 102 = b - 97 + 10
      | otherwise = error "invalid transcript hex"

recreateDirectory :: RawFilePath -> IO ()
recreateDirectory path = do
  createDirectoryIfMissing True (C.unpack path)
  forM_ ["upstream", "downstream", "abrupt-upstream", "abrupt-downstream", "concurrent-upstream", "concurrent-downstream"] $ \name ->
    removeIfPresent (path <> "/" <> name)

removeIfPresent :: RawFilePath -> IO ()
removeIfPresent path = void (try (removeLink path) :: IO (Either IOException ()))

assert :: String -> Bool -> IO ()
assert label condition = unless condition (throwIO (userError label))
