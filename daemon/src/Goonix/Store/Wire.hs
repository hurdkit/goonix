{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Primitive encodings and connection framing for the build daemon.
--
-- Wire strings and paths remain bytes.  Decoded fields retain their exact
-- source representation, including integer upper words and string padding.
module Goonix.Store.Wire
  ( Direction (..)
  , Field (..)
  , FieldKind (..)
  , FieldName (..)
  , FieldValue (..)
  , Spec (..)
  , Operation (..)
  , Handshake (..)
  , ConnectionState
  , Frame (..)
  , ParseError
  , DecodeResult (..)
  , workerMagic1
  , workerMagic2
  , protocolVersion
  , stderrNext
  , stderrRead
  , stderrWrite
  , stderrLast
  , stderrError
  , operations
  , operationByCode
  , stderrName
  , encodeInt
  , encodeBool
  , encodeWord64
  , encodeString
  , encodeStrings
  , encodeStringPairs
  , paddingLength
  , decodeInt
  , decodeBool
  , decodeWord64
  , decodeString
  , decodeStrings
  , decodeStringPairs
  , newConnection
  , connectionHandshake
  , feedBytes
  , endOfStream
  , frameLines
  , renderFrame
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as L
import Data.List (find)
import Data.Word (Word32, Word64)

data Direction = ClientToDaemon | DaemonToClient
  deriving (Eq, Ord, Show)

newtype FieldName = FieldName ByteString
  deriving (Eq, Ord, Show)

data FieldKind = IntField | BoolField | Word64Field | StringField | BytesField
  deriving (Eq, Ord, Show)

data FieldValue
  = IntValue !Word32
  | BoolValue !Bool
  | Word64Value !Word64
  | BytesValue !ByteString
  | OpaqueValue
  deriving (Eq, Ord, Show)

data Field = Field
  { fieldName :: !FieldName
  , fieldKind :: !FieldKind
  , fieldValue :: !FieldValue
  , fieldBytes :: !ByteString
  } deriving (Eq, Ord, Show)

-- | A primitive item in an operation layout.  Strings and u64 contents inside
-- an inline NAR use the same encodings, but the archive has its own framing.
data Spec
  = SInt !FieldName
  | SBool !FieldName
  | SU64 !FieldName
  | SString !FieldName
  | SStrings !FieldName
  | SPairs !FieldName
  | SNar
  | SSubstInfo !Word32
  | SSubstInfos !FieldName
  deriving (Eq, Ord, Show)

-- | All operation codes defined by the daemon.  The layouts describe the
-- current protocol; the recorder applies the minor-version conditionals.
data Operation = Operation
  { operationCode :: !Word32
  , operationName :: !ByteString
  , operationArguments :: ![Spec]
  , operationReply :: ![Spec]
  } deriving (Eq, Ord, Show)

data Handshake = Handshake
  { handshakeClientMagic :: !(Maybe Word32)
  , handshakeServerMagic :: !(Maybe Word32)
  , handshakeServerVersion :: !(Maybe Word32)
  , handshakeClientVersion :: !(Maybe Word32)
  , handshakeAffinity :: !(Maybe Word32)
  , handshakeReserveSpace :: !(Maybe Word32)
  } deriving (Eq, Ord, Show)

data Frame = Frame
  { frameHeader :: !ByteString
  , frameFields :: ![Field]
  , frameBytes :: !ByteString
  } deriving (Eq, Ord, Show)

type ParseError = ByteString

data DecodeResult a
  = Decoded !a !ByteString
  | NeedMoreInput
  | DecodeError !ParseError
  deriving (Eq, Ord, Show)

workerMagic1, workerMagic2, protocolVersion :: Word32
workerMagic1 = 0x6e697863
workerMagic2 = 0x6478696f
protocolVersion = 0x164

stderrNext, stderrRead, stderrWrite, stderrLast, stderrError :: Word32
stderrNext = 0x6f6c6d67
stderrRead = 0x64617461
stderrWrite = 0x64617416
stderrLast = 0x616c7473
stderrError = 0x63787470

name :: ByteString -> FieldName
name = FieldName

path, paths, result, status, strings :: FieldName
path = name "path"
paths = name "paths"
result = name "result"
status = name "status"
strings = name "strings"

operations :: [Operation]
operations =
  [ Operation 1 "wopIsValidPath" [SString path] [SBool result]
  , Operation 3 "wopHasSubstitutes" [SString path] [SBool result]
  , Operation 4 "wopQueryPathHash" [SString path] [SString (name "hash")]
  , Operation 5 "wopQueryReferences" [SString path] [SStrings paths]
  , Operation 6 "wopQueryReferrers" [SString path] [SStrings paths]
  , Operation 7 "wopAddToStore"
      [SString (name "baseName"), SInt (name "fixed"), SInt (name "recursive"), SString (name "hashAlgorithm"), SNar]
      [SString path]
  , Operation 8 "wopAddTextToStore"
      [SString (name "name"), SString (name "text"), SStrings (name "references")]
      [SString path]
  , Operation 9 "wopBuildPaths" [SStrings paths, SInt (name "buildMode")] [SInt status]
  , Operation 10 "wopEnsurePath" [SString path] [SInt status]
  , Operation 11 "wopAddTempRoot" [SString path] [SInt status]
  , Operation 12 "wopAddIndirectRoot" [SString path] [SInt status]
  , Operation 13 "wopSyncWithGC" [] [SInt status]
  , Operation 14 "wopFindRoots" [] [SPairs (name "roots")]
  , Operation 16 "wopExportPath" [SString path, SInt (name "sign")] [SInt status]
  , Operation 18 "wopQueryDeriver" [SString path] [SString (name "deriver")]
  , Operation 19 "wopSetOptions" (optionArguments protocolVersion) []
  , Operation 20 "wopCollectGarbage"
      [ SInt (name "action"), SStrings paths, SInt (name "ignoreLiveness")
      , SU64 (name "maxFreed"), SInt (name "obsolete")
      , SInt (name "removed"), SInt (name "removed")
      ]
      [SStrings paths, SU64 (name "bytesFreed"), SU64 (name "obsolete")]
  , Operation 21 "wopQuerySubstitutablePathInfo" [SString path] [SSubstInfo protocolVersion]
  , Operation 22 "wopQueryDerivationOutputs" [SString path] [SStrings paths]
  , Operation 23 "wopQueryAllValidPaths" [] [SStrings paths]
  , Operation 24 "wopQueryFailedPaths" [] [SStrings paths]
  , Operation 25 "wopClearFailedPaths" [SStrings paths] [SInt status]
  , Operation 26 "wopQueryPathInfo" [SString path]
      [ SString (name "deriver"), SString (name "hash"), SStrings (name "references")
      , SInt (name "registrationTime"), SU64 (name "narSize")
      ]
  , Operation 27 "wopImportPaths" [] [SStrings paths]
  , Operation 28 "wopQueryDerivationOutputNames" [SString path] [SStrings strings]
  , Operation 29 "wopQueryPathFromHashPart" [SString (name "hashPart")] [SString path]
  , Operation 30 "wopQuerySubstitutablePathInfos" [SStrings paths] [SSubstInfos (name "infos")]
  , Operation 31 "wopQueryValidPaths" [SStrings paths] [SStrings paths]
  , Operation 32 "wopQuerySubstitutablePaths" [SStrings paths] [SStrings paths]
  , Operation 33 "wopQueryValidDerivers" [SString path] [SStrings paths]
  , Operation 34 "wopOptimiseStore" [] [SInt status]
  , Operation 35 "wopVerifyStore" [SInt (name "checkContents"), SInt (name "repair")] [SBool result]
  , Operation 80 "wopBuiltinBuilders" [] [SStrings strings]
  , Operation 81 "wopSubstituteURLs" [] [SStrings strings]
  ]

operationByCode :: Word32 -> Maybe Operation
operationByCode code = find ((== code) . operationCode) operations

stderrName :: Word32 -> Maybe ByteString
stderrName tag = lookup tag
  [ (stderrNext, "STDERR_NEXT")
  , (stderrRead, "STDERR_READ")
  , (stderrWrite, "STDERR_WRITE")
  , (stderrLast, "STDERR_LAST")
  , (stderrError, "STDERR_ERROR")
  ]

paddingLength :: Int -> Int
paddingLength n = (8 - n `mod` 8) `mod` 8

encodeInt :: Word32 -> ByteString
encodeInt n = strictBuilder (Builder.word32LE n <> Builder.word32LE 0)

encodeBool :: Bool -> ByteString
encodeBool b = encodeInt (if b then 1 else 0)

encodeWord64 :: Word64 -> ByteString
encodeWord64 = strictBuilder . Builder.word64LE

encodeString :: ByteString -> ByteString
encodeString bytes = encodeInt (fromIntegral (B.length bytes)) <> bytes
  <> B.replicate (paddingLength (B.length bytes)) 0

encodeStrings :: [ByteString] -> ByteString
encodeStrings values = encodeInt (fromIntegral (length values)) <> foldMap encodeString values

encodeStringPairs :: [(ByteString, ByteString)] -> ByteString
encodeStringPairs pairs = encodeInt (fromIntegral (length pairs))
  <> foldMap (\(a, b) -> encodeString a <> encodeString b) pairs

strictBuilder :: Builder.Builder -> ByteString
strictBuilder = L.toStrict . Builder.toLazyByteString

decodeInt :: ByteString -> Either ParseError Word32
decodeInt bytes = do
  raw <- fst <$> require 8 bytes
  if B.any (/= 0) (B.drop 4 raw)
    then Left "implementation cannot deal with > 32-bit integers"
    else Right (littleWord32 raw)

decodeBool :: ByteString -> Either ParseError Bool
decodeBool bytes = (/= 0) <$> decodeInt bytes

decodeWord64 :: ByteString -> Either ParseError Word64
decodeWord64 bytes = littleWord64 . fst <$> require 8 bytes

decodeString :: ByteString -> Either ParseError ByteString
decodeString bytes = do
  len <- fromIntegral <$> decodeInt bytes
  raw <- fst <$> require (8 + len + paddingLength len) bytes
  if B.any (/= 0) (B.drop (8 + len) raw)
    then Left "non-zero padding"
    else Right (B.take len (B.drop 8 raw))

decodeStrings :: ByteString -> Either ParseError [ByteString]
decodeStrings bytes = do
  count <- fromIntegral <$> decodeInt bytes
  fst <$> stringList count (B.drop 8 bytes)

decodeStringPairs :: ByteString -> Either ParseError [(ByteString, ByteString)]
decodeStringPairs bytes = do
  count <- fromIntegral <$> decodeInt bytes
  fst <$> pairList count (B.drop 8 bytes)

stringList :: Int -> ByteString -> Either ParseError ([ByteString], ByteString)
stringList 0 rest = Right ([], rest)
stringList count rest = do
  (value, after) <- splitString rest
  (values, final) <- stringList (count - 1) after
  pure (value : values, final)

pairList :: Int -> ByteString -> Either ParseError ([(ByteString, ByteString)], ByteString)
pairList 0 rest = Right ([], rest)
pairList count rest = do
  (a, afterA) <- splitString rest
  (b, afterB) <- splitString afterA
  (pairs, final) <- pairList (count - 1) afterB
  pure ((a, b) : pairs, final)

splitString :: ByteString -> Either ParseError (ByteString, ByteString)
splitString bytes = do
  len <- fromIntegral <$> decodeInt bytes
  let size = 8 + len + paddingLength len
  value <- decodeString bytes
  pure (value, B.drop size bytes)

require :: Int -> ByteString -> Either ParseError (ByteString, ByteString)
require n bytes
  | B.length bytes < n = Left "unexpected end of input"
  | otherwise = Right (B.splitAt n bytes)

littleWord32 :: ByteString -> Word32
littleWord32 bytes =
  fromIntegral (B.index bytes 0)
  .|. (fromIntegral (B.index bytes 1) `shiftL` 8)
  .|. (fromIntegral (B.index bytes 2) `shiftL` 16)
  .|. (fromIntegral (B.index bytes 3) `shiftL` 24)

littleWord64 :: ByteString -> Word64
littleWord64 bytes =
  fromIntegral (B.index bytes 0)
  .|. (fromIntegral (B.index bytes 1) `shiftL` 8)
  .|. (fromIntegral (B.index bytes 2) `shiftL` 16)
  .|. (fromIntegral (B.index bytes 3) `shiftL` 24)
  .|. (fromIntegral (B.index bytes 4) `shiftL` 32)
  .|. (fromIntegral (B.index bytes 5) `shiftL` 40)
  .|. (fromIntegral (B.index bytes 6) `shiftL` 48)
  .|. (fromIntegral (B.index bytes 7) `shiftL` 56)

-- Incremental framing -------------------------------------------------------

data StreamState step = StreamState
  { streamStep :: !step
  , streamPending :: !ByteString
  }

data ConnectionState = ConnectionState
  { connectionHandshake :: !Handshake
  , stateClient :: !(StreamState ClientStep)
  , stateServer :: !(StreamState ServerStep)
  , stateVersion :: !Word32
  , stateCurrentOperation :: !(Maybe Operation)
  }

data ClientStep
  = CClientMagic
  | CClientVersion
  | CAffinityFlag
  | CAffinityCpu
  | CReserveSpace
  | COperation
  | CArguments !Operation !Machine
  | CNar !Operation !Machine !NarState
  | CReadData
  | CAfterRead
  | COpaque

data ServerStep
  = SMagic
  | SVersion
  | SHandshakeTag
  | SStderrTag
  | SNextPayload
  | SWritePayload
  | SReadPayload
  | SErrorMessage
  | SErrorStatus
  | SReplies !Operation !Machine
  | SOpaque

-- A list is parsed as a repeated element layout plus a continuation.  This
-- avoids allocating a list of the peer-supplied count before bytes arrive.
data Machine = Machine ![Spec] ![ListFrame]

data ListFrame = ListFrame
  { listRemaining :: !Word32
  , listElement :: ![Spec]
  , listAfter :: ![Spec]
  }

data NarState = NarState
  { narStep :: !NarStep
  , narParents :: ![NarParent]
  }

data NarParent = NarParent

data NarStep
  = NarVersion
  | NarOpen
  | NarTypeTag
  | NarType
  | NarRegularNext
  | NarExecutableValue
  | NarContentsTag
  | NarContentLength
  | NarContents !Word64 !Int
  | NarContentPadding !Int
  | NarRegularClose
  | NarTargetTag
  | NarTarget
  | NarSymlinkClose
  | NarDirectoryNext
  | NarEntryOpen
  | NarNameTag
  | NarName
  | NarNodeTag
  | NarEntryClose

data NarProgress = NarContinue !NarState | NarComplete

type Event = (ByteString, [Field])
type StepResult step = (step, Maybe Event)

newConnection :: ConnectionState
newConnection = ConnectionState
  { connectionHandshake = Handshake Nothing Nothing Nothing Nothing Nothing Nothing
  , stateClient = StreamState CClientMagic B.empty
  , stateServer = StreamState SMagic B.empty
  , stateVersion = 0
  , stateCurrentOperation = Nothing
  }

feedBytes :: Direction -> ConnectionState -> ByteString -> (ConnectionState, [Frame])
feedBytes ClientToDaemon state bytes = feedClient (appendClient state bytes) []
feedBytes DaemonToClient state bytes = feedServer (appendServer state bytes) []

appendClient :: ConnectionState -> ByteString -> ConnectionState
appendClient state bytes = state { stateClient = (stateClient state) { streamPending = streamPending (stateClient state) <> bytes } }

appendServer :: ConnectionState -> ByteString -> ConnectionState
appendServer state bytes = state { stateServer = (stateServer state) { streamPending = streamPending (stateServer state) <> bytes } }

feedClient :: ConnectionState -> [Frame] -> (ConnectionState, [Frame])
feedClient state acc =
  let stream = stateClient state
      input = streamPending stream
  in case streamStep stream of
    COpaque -> emitOpaqueClient state acc
    _ -> case nextClient state (streamStep stream) input of
      NeedMoreInput -> (state, reverse acc)
      DecodeError err -> parseFailure ClientToDaemon state err acc
      Decoded (step, event) rest ->
        let raw = B.take (B.length input - B.length rest) input
            state' = recordClientStep (streamStep stream) event step state
            state'' = state' { stateClient = StreamState step rest }
            acc' = maybe acc (\e -> makeFrame e raw : acc) event
        in feedClient state'' acc'

feedServer :: ConnectionState -> [Frame] -> (ConnectionState, [Frame])
feedServer state acc =
  let stream = stateServer state
      input = streamPending stream
  in case streamStep stream of
    SOpaque -> emitOpaqueServer state acc
    _ -> case nextServer state (streamStep stream) input of
      NeedMoreInput -> (state, reverse acc)
      DecodeError err -> parseFailure DaemonToClient state err acc
      Decoded (step, event) rest ->
        let raw = B.take (B.length input - B.length rest) input
            state' = recordServerStep (streamStep stream) event step state
            state'' = state' { stateServer = StreamState step rest }
            acc' = maybe acc (\e -> makeFrame e raw : acc) event
        in feedServer state'' acc'

makeFrame :: Event -> ByteString -> Frame
makeFrame (header, fields) raw = Frame header fields raw

emitOpaqueClient :: ConnectionState -> [Frame] -> (ConnectionState, [Frame])
emitOpaqueClient state acc
  | B.null input = (state, reverse acc)
  | otherwise = (state { stateClient = StreamState COpaque B.empty }, reverse (Frame "unframed" [] input : acc))
  where input = streamPending (stateClient state)

emitOpaqueServer :: ConnectionState -> [Frame] -> (ConnectionState, [Frame])
emitOpaqueServer state acc
  | B.null input = (state, reverse acc)
  | otherwise = (state { stateServer = StreamState SOpaque B.empty }, reverse (Frame "unframed" [] input : acc))
  where input = streamPending (stateServer state)

parseFailure :: Direction -> ConnectionState -> ParseError -> [Frame] -> (ConnectionState, [Frame])
parseFailure ClientToDaemon state err acc = parseFailureClient state err acc
parseFailure DaemonToClient state err acc = parseFailureServer state err acc

parseFailureClient :: ConnectionState -> ParseError -> [Frame] -> (ConnectionState, [Frame])
parseFailureClient state err acc =
  let input = streamPending (stateClient state)
      event = ("parse-error " <> hex err, [Field (name "bytes") BytesField OpaqueValue input])
      state' = state { stateClient = StreamState COpaque B.empty }
  in (state', reverse (makeFrame event input : acc))

parseFailureServer :: ConnectionState -> ParseError -> [Frame] -> (ConnectionState, [Frame])
parseFailureServer state err acc =
  let input = streamPending (stateServer state)
      event = ("parse-error " <> hex err, [Field (name "bytes") BytesField OpaqueValue input])
      state' = state { stateServer = StreamState SOpaque B.empty }
  in (state', reverse (makeFrame event input : acc))

recordClientStep :: ClientStep -> Maybe Event -> ClientStep -> ConnectionState -> ConnectionState
recordClientStep previous event _ state = case (previous, event >>= fieldOf) of
  (CClientMagic, Just f) -> state { connectionHandshake = (connectionHandshake state) { handshakeClientMagic = fieldInt f } }
  (CClientVersion, Just f) ->
    let version = maybe 0 id (fieldInt f)
    in state { connectionHandshake = (connectionHandshake state) { handshakeClientVersion = Just version }, stateVersion = version }
  (CAffinityFlag, Just f) -> state { connectionHandshake = (connectionHandshake state) { handshakeAffinity = fieldInt f } }
  (CReserveSpace, Just f) -> state { connectionHandshake = (connectionHandshake state) { handshakeReserveSpace = fieldInt f } }
  (COperation, Just f) -> state { stateCurrentOperation = fieldInt f >>= operationByCode }
  _ -> state
  where
    fieldOf (_, fields) = case fields of
      f : _ -> Just f
      [] -> Nothing

recordServerStep :: ServerStep -> Maybe Event -> ServerStep -> ConnectionState -> ConnectionState
recordServerStep previous event next state0 =
  let state1 = case (previous, event >>= fieldOf) of
        (SMagic, Just f) -> state0 { connectionHandshake = (connectionHandshake state0) { handshakeServerMagic = fieldInt f } }
        (SVersion, Just f) -> state0 { connectionHandshake = (connectionHandshake state0) { handshakeServerVersion = fieldInt f } }
        _ -> state0
      state2 = case previous of
        SReadPayload -> state1 { stateClient = (stateClient state1) { streamStep = CReadData } }
        SNextPayload -> state1 { stateClient = (stateClient state1) { streamStep = CAfterRead } }
        SWritePayload -> state1 { stateClient = (stateClient state1) { streamStep = CAfterRead } }
        SErrorStatus -> state1 { stateCurrentOperation = Nothing }
        SErrorMessage | protocolMinor (stateVersion state1) < 8 -> state1 { stateCurrentOperation = Nothing }
        SHandshakeTag -> state1
        SStderrTag -> state1
        SReplies _ _ -> case next of
          SStderrTag -> state1 { stateCurrentOperation = Nothing }
          _ -> state1
        _ -> state1
  in state2
  where
    fieldOf (_, fields) = case fields of
      f : _ -> Just f
      [] -> Nothing

fieldInt :: Field -> Maybe Word32
fieldInt f = case fieldValue f of
  IntValue n -> Just n
  BoolValue b -> Just (if b then 1 else 0)
  _ -> Nothing

nextClient :: ConnectionState -> ClientStep -> ByteString -> DecodeResult (StepResult ClientStep)
nextClient state step input = case step of
  CClientMagic -> intEvent "handshake client-magic" (name "magic") input $ \f _ ->
    if fieldInt f == Just workerMagic1 then CClientVersion else COpaque
  CClientVersion -> intEvent "handshake client-version" (name "version") input $ \f _ ->
    clientAfterVersion (maybe 0 id (fieldInt f))
  CAffinityFlag -> intEvent "handshake affinity" (name "enabled") input $ \f _ ->
    if fieldInt f == Just 0 then afterAffinity (stateVersion state) else CAffinityCpu
  CAffinityCpu -> intEvent "handshake cpu" (name "cpu") input $ \_ _ -> CReserveSpace
  CReserveSpace -> intEvent "handshake reserve-space" (name "enabled") input $ \_ _ -> COperation
  COperation -> case parseInt (name "code") input of
    NeedMoreInput -> NeedMoreInput
    DecodeError err -> DecodeError err
    Decoded f rest -> case fieldInt f >>= operationByCode of
      Nothing -> Decoded (COpaque, Just ("operation unknown", [f])) rest
      Just op -> Decoded (CArguments op (Machine (requestSpecs (stateVersion state) op) []), Just ("operation", [f])) rest
  CArguments op machine -> case normalizeMachine machine of
    Machine [] [] -> Decoded (COperation, Nothing) input
    Machine (SNar : rest) stack -> Decoded (CNar op (Machine rest stack) (NarState NarVersion []), Nothing) input
    normalized -> machineEvent "request" op normalized input $ \m -> CArguments op m
  CNar op machine nar -> case nextNar nar input of
    Left err -> DecodeError err
    Right (Nothing, _) -> NeedMoreInput
    Right (Just (progress, event), rest) ->
      let next = case progress of
            NarContinue nar' -> CNar op machine nar'
            NarComplete -> CArguments op machine
      in Decoded (next, event) rest
  CReadData -> stringEvent "stderr-read-data" (name "data") input (\_ _ -> CAfterRead)
  CAfterRead -> NeedMoreInput
  COpaque -> Decoded (COpaque, Nothing) B.empty

clientAfterVersion :: Word32 -> ClientStep
clientAfterVersion version
  | protocolMinor version >= 14 = CAffinityFlag
  | protocolMinor version >= 11 = CReserveSpace
  | otherwise = COperation

afterAffinity :: Word32 -> ClientStep
afterAffinity version
  | protocolMinor version >= 11 = CReserveSpace
  | otherwise = COperation

nextServer :: ConnectionState -> ServerStep -> ByteString -> DecodeResult (StepResult ServerStep)
nextServer state step input = case step of
  SMagic -> intEvent "handshake server-magic" (name "magic") input $ \f _ ->
    if fieldInt f == Just workerMagic2 then SVersion else SOpaque
  SVersion -> intEvent "handshake server-version" (name "version") input (\_ _ -> SHandshakeTag)
  SHandshakeTag -> intEvent "handshake stderr" (name "tag") input $ \f _ -> case fieldInt f of
    Just tag
      | tag == stderrLast -> SStderrTag
      | tag == stderrError -> SErrorMessage
    _ -> SOpaque
  SStderrTag -> intEvent "stderr" (name "tag") input $ \f _ -> case fieldInt f of
    Just tag
      | tag == stderrNext -> SNextPayload
      | tag == stderrWrite -> SWritePayload
      | tag == stderrRead -> SReadPayload
      | tag == stderrError -> SErrorMessage
      | tag == stderrLast -> case stateCurrentOperation state of
          Nothing -> SStderrTag
          Just op -> SReplies op (Machine (responseSpecs (stateVersion state) op) [])
    _ -> SOpaque
  SNextPayload -> stringEvent "STDERR_NEXT" (name "text") input (\_ _ -> SStderrTag)
  SWritePayload -> stringEvent "STDERR_WRITE" (name "data") input (\_ _ -> SStderrTag)
  SReadPayload -> intEvent "STDERR_READ" (name "maxLength") input (\_ _ -> SStderrTag)
  SErrorMessage -> stringEvent "STDERR_ERROR" (name "message") input $ \_ _ ->
    if protocolMinor (stateVersion state) >= 8 then SErrorStatus else SStderrTag
  SErrorStatus -> intEvent "STDERR_ERROR" (name "status") input (\_ _ -> SStderrTag)
  SReplies op machine -> case normalizeMachine machine of
    Machine [] [] -> Decoded (SStderrTag, Nothing) input
    Machine (SNar : _) _ -> DecodeError "NAR in operation reply"
    normalized -> machineEvent "reply" op normalized input $ \m -> SReplies op m
  SOpaque -> Decoded (SOpaque, Nothing) B.empty

intEvent :: ByteString -> FieldName -> ByteString -> (Field -> ByteString -> step) -> DecodeResult (StepResult step)
intEvent header fieldName' input continue = case parseInt fieldName' input of
  NeedMoreInput -> NeedMoreInput
  DecodeError err -> DecodeError err
  Decoded f rest -> Decoded (continue f rest, Just (header, [f])) rest

stringEvent :: ByteString -> FieldName -> ByteString -> (Field -> ByteString -> step) -> DecodeResult (StepResult step)
stringEvent header fieldName' input continue = case parseString fieldName' input of
  NeedMoreInput -> NeedMoreInput
  DecodeError err -> DecodeError err
  Decoded f rest -> Decoded (continue f rest, Just (header, [f])) rest

machineEvent :: ByteString -> Operation -> Machine -> ByteString -> (Machine -> step) -> DecodeResult (StepResult step)
machineEvent prefix op (Machine (spec : rest) stack) input continue = case spec of
  SInt n -> primitive n IntField parseInt (\m -> continue m)
  SBool n -> primitive n BoolField parseBool (\m -> continue m)
  SU64 n -> primitive n Word64Field parseWord64 (\m -> continue m)
  SString n -> primitive n StringField parseString (\m -> continue m)
  SStrings n -> listCount n [SString (appendName n "item")]
  SPairs n -> listCount n [SString (appendName n "key"), SString (appendName n "value")]
  SSubstInfos n -> listCount n (substInfoItems (name "info"))
  SSubstInfo version -> case parseInt (name "present") input of
    NeedMoreInput -> NeedMoreInput
    DecodeError err -> DecodeError err
    Decoded f remaining ->
      let present = fieldInt f /= Just 0
          specs = if present then singleSubstInfoItems version else []
          machine = Machine (specs ++ rest) stack
      in Decoded (continue machine, Just (eventFor prefix op (name "present"), [f])) remaining
  SNar -> DecodeError "unexpected inline NAR"
  where
    primitive n _ parser k = case parser n input of
      NeedMoreInput -> NeedMoreInput
      DecodeError err -> DecodeError err
      Decoded f remaining -> Decoded (k (Machine rest stack), Just (eventFor prefix op n, [f])) remaining
    listCount n element = case parseInt (appendName n "count") input of
      NeedMoreInput -> NeedMoreInput
      DecodeError err -> DecodeError err
      Decoded f remaining ->
        let count = maybe 0 id (fieldInt f)
            machine = if count == 0 then Machine rest stack
              else Machine element (ListFrame count element rest : stack)
        in Decoded (continue machine, Just (eventFor prefix op (appendName n "count"), [f])) remaining
machineEvent _ _ (Machine [] _) _ _ = DecodeError "empty field sequence"

eventFor :: ByteString -> Operation -> FieldName -> ByteString
eventFor prefix op n = prefix <> " " <> operationName op <> " " <> nameBytes n

appendName :: FieldName -> ByteString -> FieldName
appendName n suffix = FieldName (nameBytes n <> "." <> suffix)

normalizeMachine :: Machine -> Machine
normalizeMachine (Machine [] (frame : rest))
  | listRemaining frame > 1 = Machine (listElement frame) (frame { listRemaining = listRemaining frame - 1 } : rest)
  | otherwise = normalizeMachine (Machine (listAfter frame) rest)
normalizeMachine machine = machine

requestSpecs :: Word32 -> Operation -> [Spec]
requestSpecs version op = case operationCode op of
  9 -> [SStrings paths] ++ [SInt (name "buildMode") | protocolMinor version >= 15]
  19 -> optionArguments version
  20 -> [SInt (name "action"), SStrings paths, SInt (name "ignoreLiveness"), SU64 (name "maxFreed"), SInt (name "obsolete")]
    ++ if protocolMinor version >= 5 then [SInt (name "removed"), SInt (name "removed")] else []
  _ -> operationArguments op

optionArguments :: Word32 -> [Spec]
optionArguments version =
  [SInt (name "keepFailed"), SInt (name "keepGoing"), SInt (name "tryFallback"), SInt (name "verbosity")]
  ++ (if minor < 0x61 then [SInt (name "maxBuildJobs"), SInt (name "maxSilentTime")] else [])
  ++ (if minor >= 2 then [SInt (name "useBuildHook")] else [])
  ++ (if minor >= 4 then [SInt (name "buildVerbosity"), SInt (name "logType"), SInt (name "printBuildTrace")] else [])
  ++ (if minor >= 6 && minor < 0x61 then [SInt (name "buildCores")] else [])
  ++ (if minor >= 10 then [SInt (name "useSubstitutes")] else [])
  ++ (if minor >= 12 then [SPairs (name "overrides")] else [])
  where minor = protocolMinor version

responseSpecs :: Word32 -> Operation -> [Spec]
responseSpecs version op
  | operationCode op == 21 = [SSubstInfo version]
  | otherwise = operationReply op

singleSubstInfoItems :: Word32 -> [Spec]
singleSubstInfoItems version =
  [SString (name "deriver"), SStrings (name "references"), SU64 (name "downloadSize")]
  ++ (if protocolMinor version >= 7 then [SU64 (name "narSize")] else [])

substInfoItems :: FieldName -> [Spec]
substInfoItems prefix =
  [ SString (appendName prefix "path"), SString (appendName prefix "deriver")
  , SStrings (appendName prefix "references"), SU64 (appendName prefix "downloadSize")
  , SU64 (appendName prefix "narSize")
  ]

protocolMinor :: Word32 -> Word32
protocolMinor version = version .&. 0xff

-- Primitive incremental fields ---------------------------------------------

parseInt :: FieldName -> ByteString -> DecodeResult Field
parseInt n input
  | B.length input < 8 = NeedMoreInput
  | B.any (/= 0) (B.take 4 (B.drop 4 input)) = DecodeError "implementation cannot deal with > 32-bit integers"
  | otherwise = Decoded (Field n IntField (IntValue (littleWord32 input)) (B.take 8 input)) (B.drop 8 input)

parseBool :: FieldName -> ByteString -> DecodeResult Field
parseBool n input = case parseInt n input of
  Decoded f rest -> Decoded f { fieldKind = BoolField, fieldValue = BoolValue (fieldInt f /= Just 0) } rest
  NeedMoreInput -> NeedMoreInput
  DecodeError err -> DecodeError err

parseWord64 :: FieldName -> ByteString -> DecodeResult Field
parseWord64 n input
  | B.length input < 8 = NeedMoreInput
  | otherwise = Decoded (Field n Word64Field (Word64Value (littleWord64 input)) (B.take 8 input)) (B.drop 8 input)

parseString :: FieldName -> ByteString -> DecodeResult Field
parseString n input = case decodeString input of
  Left "unexpected end of input" -> NeedMoreInput
  Left err -> DecodeError err
  Right value ->
    let len = fromIntegral (littleWord32 input) :: Int
        size = 8 + len + paddingLength len
    in Decoded (Field n StringField (BytesValue value) (B.take size input)) (B.drop size input)

-- Inline NAR framing --------------------------------------------------------

nextNar :: NarState -> ByteString -> Either ParseError (Maybe (NarProgress, Maybe Event), ByteString)
nextNar state input = case narStep state of
  NarVersion -> expected "version" "nix-archive-1" (continue NarOpen)
  NarOpen -> expected "open" "(" (continue NarTypeTag)
  NarTypeTag -> expected "type-tag" "type" (continue NarType)
  NarType -> stringField $ \f -> case fieldBytesValue f of
    Just "regular" -> continue NarRegularNext f
    Just "symlink" -> continue NarTargetTag f
    Just "directory" -> continue NarDirectoryNext f
    _ -> Left "bad archive: unknown type"
  NarRegularNext -> stringField $ \f -> case fieldBytesValue f of
    Just "executable" -> continue NarExecutableValue f
    Just "contents" -> continue NarContentLength f
    _ -> Left "bad archive: expected contents tag"
  NarExecutableValue -> stringField (continue NarContentsTag)
  NarContentsTag -> expected "contents-tag" "contents" (continue NarContentLength)
  NarContentLength -> case parseWord64 (name "content-length") input of
    NeedMoreInput -> Right (Nothing, input)
    DecodeError err -> Left err
    Decoded f rest ->
      let len = fieldWord64 f
          pad = paddingLength (fromIntegral (len .&. 7))
          next = if len == 0 then NarContentPadding pad else NarContents len pad
      in produced (NarContinue state { narStep = next }) (narEvent "content-length" [f]) rest
  NarContents remaining pad
    | B.null input -> Right (Nothing, input)
    | otherwise ->
        let amount = fromIntegral (min remaining (fromIntegral (B.length input)))
            left = remaining - fromIntegral amount
            next = if left == 0 then NarContentPadding pad else NarContents left pad
        in produced (NarContinue state { narStep = next }) ("nar contents", []) (B.drop amount input)
  NarContentPadding remaining
    | remaining == 0 -> produced (NarContinue state { narStep = NarRegularClose }) ("nar padding", []) input
    | B.null input -> Right (Nothing, input)
    | otherwise ->
        let amount = min remaining (B.length input)
            raw = B.take amount input
        in if B.any (/= 0) raw then Left "non-zero padding"
           else produced (NarContinue state { narStep = NarContentPadding (remaining - amount) }) ("nar padding", []) (B.drop amount input)
  NarRegularClose -> expected "regular-close" ")" nodeFinished
  NarTargetTag -> expected "target-tag" "target" (continue NarTarget)
  NarTarget -> stringField (continue NarSymlinkClose)
  NarSymlinkClose -> expected "symlink-close" ")" nodeFinished
  NarDirectoryNext -> stringField $ \f -> case fieldBytesValue f of
    Just ")" -> nodeFinished f
    Just "entry" -> continue NarEntryOpen f
    _ -> Left "bad archive: expected entry tag"
  NarEntryOpen -> expected "entry-open" "(" (continue NarNameTag)
  NarNameTag -> expected "name-tag" "name" (continue NarName)
  NarName -> stringField (continue NarNodeTag)
  NarNodeTag -> expected "node-tag" "node" continueWithParents
  NarEntryClose -> expected "entry-close" ")" (continue NarDirectoryNext)
  where
    produced progress event rest = Right (Just (progress, Just event), rest)
    continue next f = produced (NarContinue state { narStep = next }) (narEvent (stepLabel (narStep state)) [f]) (B.drop (B.length (fieldBytes f)) input)
    continueWithParents f = produced (NarContinue (NarState NarOpen (NarParent : narParents state))) (narEvent (stepLabel (narStep state)) [f]) (B.drop (B.length (fieldBytes f)) input)
    nodeFinished f = case narParents state of
      [] -> produced NarComplete (narEvent (stepLabel (narStep state)) [f]) (B.drop (B.length (fieldBytes f)) input)
      _ : parents -> produced (NarContinue (NarState NarEntryClose parents)) (narEvent (stepLabel (narStep state)) [f]) (B.drop (B.length (fieldBytes f)) input)
    expected label wanted k = case parseString (name label) input of
      NeedMoreInput -> Right (Nothing, input)
      DecodeError err -> Left err
      Decoded f _
        | fieldBytesValue f /= Just wanted -> Left ("bad archive: expected " <> wanted)
        | otherwise -> k f
    stringField k = case parseString (name "nar-value") input of
      NeedMoreInput -> Right (Nothing, input)
      DecodeError err -> Left err
      Decoded f _ -> k f

narEvent :: ByteString -> [Field] -> Event
narEvent label fields = ("nar " <> label, fields)

stepLabel :: NarStep -> ByteString
stepLabel step = case step of
  NarVersion -> "version"
  NarOpen -> "open"
  NarTypeTag -> "type-tag"
  NarType -> "type"
  NarRegularNext -> "regular-next"
  NarExecutableValue -> "executable-value"
  NarContentsTag -> "contents-tag"
  NarContentLength -> "content-length"
  NarContents _ _ -> "contents"
  NarContentPadding _ -> "padding"
  NarRegularClose -> "regular-close"
  NarTargetTag -> "target-tag"
  NarTarget -> "target"
  NarSymlinkClose -> "symlink-close"
  NarDirectoryNext -> "directory-next"
  NarEntryOpen -> "entry-open"
  NarNameTag -> "name-tag"
  NarName -> "name"
  NarNodeTag -> "node-tag"
  NarEntryClose -> "entry-close"

fieldBytesValue :: Field -> Maybe ByteString
fieldBytesValue f = case fieldValue f of
  BytesValue bytes -> Just bytes
  _ -> Nothing

fieldWord64 :: Field -> Word64
fieldWord64 f = case fieldValue f of
  Word64Value n -> n
  _ -> 0

-- End-of-stream and rendering ----------------------------------------------

endOfStream :: Direction -> ConnectionState -> (ConnectionState, [Frame])
endOfStream ClientToDaemon state
  | B.null pending = (state, [])
  | otherwise = (state { stateClient = (stateClient state) { streamPending = B.empty } }, [partial pending])
  where pending = streamPending (stateClient state)
endOfStream DaemonToClient state
  | B.null pending = (state, [])
  | otherwise = (state { stateServer = (stateServer state) { streamPending = B.empty } }, [partial pending])
  where pending = streamPending (stateServer state)

partial :: ByteString -> Frame
partial bytes = Frame "partial" [Field (name "bytes") BytesField OpaqueValue bytes] bytes

frameLines :: Frame -> [ByteString]
frameLines frame = [frameHeader frame]
  ++ concatMap renderField (frameFields frame)
  ++ ["raw " <> hex (frameBytes frame)]

renderFrame :: Frame -> ByteString
renderFrame frame = B.intercalate "\n" (frameLines frame) <> "\n"

renderField :: Field -> [ByteString]
renderField f = [nameBytes (fieldName f) <> " " <> kindName (fieldKind f) <> " " <> valueText (fieldValue f)]
  where
    valueText (IntValue n) = asciiShow n
    valueText (BoolValue b) = if b then "true" else "false"
    valueText (Word64Value n) = asciiShow n
    valueText (BytesValue bytes) = "hex:" <> hex bytes
    valueText OpaqueValue = "opaque"

kindName :: FieldKind -> ByteString
kindName IntField = "int"
kindName BoolField = "bool"
kindName Word64Field = "u64"
kindName StringField = "string"
kindName BytesField = "bytes"

asciiShow :: Show a => a -> ByteString
asciiShow = B.pack . map (fromIntegral . fromEnum) . show

hex :: ByteString -> ByteString
hex = B.concatMap byteHex
  where
    byteHex b = B.pack [digits !! fromIntegral (b `shiftR` 4), digits !! fromIntegral (b .&. 15)]
    digits = map (fromIntegral . fromEnum) "0123456789abcdef"

nameBytes :: FieldName -> ByteString
nameBytes (FieldName bytes) = bytes
