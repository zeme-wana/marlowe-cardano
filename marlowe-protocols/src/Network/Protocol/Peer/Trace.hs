{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Network.Protocol.Peer.Trace
  where

import Control.Monad (join, replicateM)
import Control.Monad.Event.Class (MonadEvent, withInjectEventArgs, withInjectEventFields)
import Control.Monad.IO.Class (MonadIO)
import Data.Binary (Binary, get, getWord8, put)
import Data.Binary.Put (putWord8, runPut)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (ByteString)
import Data.Foldable (traverse_)
import Data.Functor ((<&>))
import Data.Proxy
import Data.Text (Text)
import Network.Channel
import Network.Protocol.Codec (BinaryMessage, DeserializeError, binaryCodec, decodeGet)
import Network.TypedProtocol
import Network.TypedProtocol.Codec
import Observe.Event (Event(addField), InjectSelector, NewEventArgs(..), reference)
import Observe.Event.Backend (simpleNewEventArgs)
import Observe.Event.Render.OpenTelemetry
import OpenTelemetry.Trace.Core
import OpenTelemetry.Trace.Id (SpanId, TraceId, bytesToSpanId, bytesToTraceId, spanIdBytes, traceIdBytes)
import OpenTelemetry.Trace.TraceState (Key(..), TraceState, Value(..), empty, insert, toList)
import qualified OpenTelemetry.Trace.TraceState as TraceState
import UnliftIO (throwIO)

-- | A peer in a protocol session which is suitable for tracing.
data PeerTraced ps (pr :: PeerRole) (st :: ps) m a where
  -- | A peer sends a message to the other peer.
  YieldTraced
    :: WeHaveAgency pr st
    -> Message ps st st'
    -> YieldTraced ps pr st' m a
    -> PeerTraced ps pr st m a

  -- | A peer awaits a message from the other peer.
  AwaitTraced
    :: TheyHaveAgency pr st
    -> (forall (st' :: ps). Message ps st st' -> AwaitTraced ps pr st' m a)
    -> PeerTraced ps pr st m a

  -- | A peer is processing information.
  EffectTraced
    :: m (PeerTraced ps pr st m a)
    -> PeerTraced ps pr st m a

  -- | The session is done.
  DoneTraced
    :: NobodyHasAgency st
    -> a
    -> PeerTraced ps pr st m a

deriving instance Functor m => Functor (PeerTraced ps pr st m)

data YieldTraced ps (pr :: PeerRole) (st :: ps) m a where
  Call
    :: TheyHaveAgency pr st
    -> (forall st'. Message ps st st' -> PeerTraced ps pr st' m a)
    -> YieldTraced ps pr st m a
  Cast
    :: PeerTraced ps pr st m a
    -> YieldTraced ps pr st m a
  Close
    :: NobodyHasAgency st
    -> a
    -> YieldTraced ps pr st m a

deriving instance Functor m => Functor (YieldTraced ps pr st m)

data AwaitTraced ps pr st m a where
  Respond
    :: WeHaveAgency pr st
    -> m (Response ps pr st m a)
    -> AwaitTraced ps pr st m a
  Receive
    :: PeerTraced ps pr st m a
    -> AwaitTraced ps pr st m a
  Closed
    :: NobodyHasAgency st
    -> m a
    -> AwaitTraced ps pr st m a

deriving instance Functor m => Functor (AwaitTraced ps pr st m)

data Response ps pr st m a where
  Response
    :: Message ps st st'
    -> PeerTraced ps pr st' m a
    -> Response ps pr st m a

deriving instance Functor m => Functor (Response ps pr st m)

hoistPeerTraced
  :: Functor m
  => (forall x. m x -> n x)
  -> PeerTraced ps pr st m a
  -> PeerTraced ps pr st n a
hoistPeerTraced f = \case
  YieldTraced tok msg yield -> YieldTraced tok msg case yield of
    Call tok' k -> Call tok' $ hoistPeerTraced f . k
    Cast next -> Cast $ hoistPeerTraced f next
    Close tok' a -> Close tok' a
  AwaitTraced tok k -> AwaitTraced tok \msg -> case k msg of
    Respond tok' m -> Respond tok' $ f $ m <&> \case
      Response msg' next -> Response msg' $ hoistPeerTraced f next
    Receive next -> Receive $ hoistPeerTraced f next
    Closed tok' ma -> Closed tok' $ f ma
  DoneTraced tok a -> DoneTraced tok a
  EffectTraced m -> EffectTraced $ f $ hoistPeerTraced f <$> m

peerTracedToPeer :: Functor m => PeerTraced ps pr st m a -> Peer ps pr st m a
peerTracedToPeer = \case
  YieldTraced tok msg yield -> Yield tok msg case yield of
    Call tok' k -> Await tok' $ peerTracedToPeer . k
    Cast next -> peerTracedToPeer next
    Close tok' a -> Done tok' a
  AwaitTraced tok k -> Await tok \msg -> case k msg of
    Respond tok' m -> Effect $ m <&> \case
      Response msg' next -> Yield tok' msg' $ peerTracedToPeer next
    Receive next -> peerTracedToPeer next
    Closed tok' ma -> Effect $ Done tok' <$> ma
  DoneTraced tok a -> Done tok a
  EffectTraced m -> Effect $ peerTracedToPeer <$> m

data DriverTraced ps dState r m = DriverTraced
  { sendMessageTraced
      :: forall pr st st'
       . r
      -> PeerHasAgency pr st
      -> Message ps st st'
      -> m ()
  , recvMessageTraced
      :: forall pr (st :: ps)
       . PeerHasAgency pr st
      -> dState
      -> m (r, SomeMessage st, dState)
  , startDStateTraced :: dState
  }

hoistDriverTraced :: (forall x. m x -> n x) -> DriverTraced ps dState r m -> DriverTraced ps dState r n
hoistDriverTraced f DriverTraced{..} = DriverTraced
  { sendMessageTraced = \r tok -> f . sendMessageTraced r tok
  , recvMessageTraced = \tok -> f . recvMessageTraced tok
  , ..
  }

data TypedProtocolsSelector ps f where
  ReceiveSelector :: PeerHasAgency pr st -> Message ps st st' -> TypedProtocolsSelector ps ()
  CallSelector :: PeerHasAgency pr st -> Message ps st st' -> TypedProtocolsSelector ps (Maybe (AnyMessageAndAgency ps))
  RespondSelector :: PeerHasAgency pr st -> Message ps st st' -> TypedProtocolsSelector ps (Maybe (AnyMessageAndAgency ps))
  CastSelector :: PeerHasAgency pr st -> Message ps st st' -> TypedProtocolsSelector ps ()
  CloseSelector :: PeerHasAgency pr st -> Message ps st st' -> TypedProtocolsSelector ps ()

runPeerWithDriverTraced
  :: forall ps dState pr st r s m a
   . MonadEvent r s m
  => InjectSelector (TypedProtocolsSelector ps) s
  -> DriverTraced ps dState r m
  -> PeerTraced ps pr st m a
  -> dState
  -> m a
runPeerWithDriverTraced inj driver peer dState = case peer of
  EffectTraced m -> flip (runPeerWithDriverTraced inj driver) dState =<< m
  YieldTraced tok msg yield -> runYieldPeerWithDriverTraced inj driver tok msg dState yield
  AwaitTraced tok k -> runAwaitPeerWithDriverTraced inj driver tok k dState
  DoneTraced _ a -> pure a

runYieldPeerWithDriverTraced
  :: MonadEvent r s m
  => InjectSelector (TypedProtocolsSelector ps) s
  -> DriverTraced ps dState r m
  -> WeHaveAgency pr st
  -> Message ps st st'
  -> dState
  -> YieldTraced ps pr st' m a
  -> m a
runYieldPeerWithDriverTraced inj driver tok msg dState = \case
  Call tok' k -> join $ withInjectEventFields inj (CallSelector tok msg) [Nothing] \callEv -> do
    sendMessageTraced driver (reference callEv) tok msg
    (_, SomeMessage msg', dState') <- recvMessageTraced driver tok' dState
    addField callEv $ Just $ AnyMessageAndAgency tok' msg'
    pure $ runPeerWithDriverTraced inj driver (k msg') dState'

  Cast peer -> join $ withInjectEventFields inj (CastSelector tok msg) [()] \castEv -> do
    sendMessageTraced driver (reference castEv) tok msg
    pure $ runPeerWithDriverTraced inj driver peer dState

  Close _ a -> withInjectEventFields inj (CloseSelector tok msg) [()] \closeEv -> do
    sendMessageTraced driver (reference closeEv) tok msg
    pure a

runAwaitPeerWithDriverTraced
  :: forall ps pr st dState r s m a
   . MonadEvent r s m
  => InjectSelector (TypedProtocolsSelector ps) s
  -> DriverTraced ps dState r m
  -> TheyHaveAgency pr st
  -> (forall (st' :: ps). Message ps st st' -> AwaitTraced ps pr st' m a)
  -> dState
  -> m a
runAwaitPeerWithDriverTraced inj driver tok k dState = do
  (sendRef, SomeMessage msg, dState') <- recvMessageTraced driver tok dState
  case k msg of
    Respond tok' m -> join $ withInjectEventArgs inj (respondArgs sendRef tok msg) \respondEv -> do
      Response msg' nextPeer <- m
      addField respondEv $ Just $ AnyMessageAndAgency tok' msg'
      sendMessageTraced driver (reference respondEv) tok' msg'
      pure $ runPeerWithDriverTraced inj driver nextPeer dState'
    Receive nextPeer -> join $ withInjectEventArgs inj (receiveArgs sendRef tok msg) $ const $ receive nextPeer
    Closed _ ma -> withInjectEventArgs inj (closeArgs sendRef tok msg) $ const ma
  where
    receive :: PeerTraced ps pr st' m a -> m (m a)
    receive = \case
      EffectTraced m -> receive =<< m
      peer -> pure $ runPeerWithDriverTraced inj driver peer dState
    respondArgs sendRef tok' msg = (simpleNewEventArgs (RespondSelector tok' msg))
      { newEventParent = Just sendRef
      , newEventInitialFields = [Nothing]
      }
    receiveArgs sendRef tok' msg = (simpleNewEventArgs (ReceiveSelector tok' msg))
      { newEventParent = Just sendRef
      , newEventInitialFields = [()]
      }
    closeArgs sendRef tok' msg = (simpleNewEventArgs (CloseSelector tok' msg))
      { newEventParent = Just sendRef
      , newEventInitialFields = [()]
      }

class HasSpanContext r where
  context :: MonadIO m => r -> m SpanContext
  wrapContext :: SpanContext -> r

defaultSpanContext :: SpanContext
defaultSpanContext = SpanContext
  defaultTraceFlags
  False
  "00000000000000000000000000000000"
  "0000000000000000"
  TraceState.empty

data MessageAttributes = MessageAttributes
  { messageType :: Text
  , messageParameters :: [PrimitiveAttribute]
  }

class Protocol ps => OTelProtocol ps where
  protocolName :: Proxy ps -> Text
  messageAttributes :: PeerHasAgency pr st -> Message ps st st' -> MessageAttributes

instance HasSpanContext Span where
  context = getSpanContext
  wrapContext = wrapSpanContext

instance (Monoid b, HasSpanContext a) => HasSpanContext (a, b) where
  context = context . fst
  wrapContext = (,mempty) . wrapContext

mkDriverTraced
  :: forall ps r m
   . (MonadIO m, BinaryMessage ps, HasSpanContext r)
  => Channel m ByteString
  -> DriverTraced ps (Maybe ByteString) r m
mkDriverTraced Channel{..} = DriverTraced{..}
  where
    Codec{..} = binaryCodec
    sendMessageTraced
      :: forall (pr :: PeerRole) (st :: ps) (st' :: ps)
       . r
      -> PeerHasAgency pr st
      -> Message ps st st'
      -> m ()
    sendMessageTraced r tok msg = do
      spanContext <- context r
      send $ runPut (put spanContext) <> encode tok msg

    recvMessageTraced
      :: forall (pr :: PeerRole) (st :: ps)
       . PeerHasAgency pr st
      -> Maybe ByteString
      -> m (r, SomeMessage st, Maybe ByteString)
    recvMessageTraced tok trailing = do
      (r, trailing') <- decodeChannel trailing =<< decodeGet (wrapContext <$> get)
      (msg, trailing'') <- decodeChannel trailing' =<< decode tok
      pure (r, msg, trailing'')

    decodeChannel
      :: Maybe ByteString
      -> DecodeStep ByteString DeserializeError m a
      -> m (a, Maybe ByteString)
    decodeChannel _ (DecodeDone a trailing)     = pure (a, trailing)
    decodeChannel _ (DecodeFail failure)        = throwIO failure
    decodeChannel Nothing (DecodePartial next)  = recv >>= next >>= decodeChannel Nothing
    decodeChannel trailing (DecodePartial next) = next trailing >>= decodeChannel Nothing

    startDStateTraced :: Maybe ByteString
    startDStateTraced = Nothing

instance Binary TraceFlags where
  put = putWord8 . traceFlagsValue
  get = traceFlagsFromWord8 <$> getWord8

instance Binary TraceId where
  put = traverse_ putWord8 . B.unpack . traceIdBytes
  get = either fail pure . bytesToTraceId . B.pack =<< replicateM 16 getWord8

instance Binary SpanId where
  put = traverse_ putWord8 . B.unpack . spanIdBytes
  get = either fail pure . bytesToSpanId . B.pack =<< replicateM 8 getWord8

instance Binary TraceState where
  put = put . toList
  get = fromList <$> get
    where
      fromList :: [(Key, Value)] -> TraceState
      fromList = foldr (uncurry insert) empty

instance Binary Key where
  put (Key t) = put t
  get = Key <$> get

instance Binary Value where
  put (Value t) = put t
  get = Value <$> get

instance Binary SpanContext where
  put SpanContext{..} = do
    put traceFlags
    put traceId
    put spanId
    put traceState
  get = do
    traceFlags <- get
    let isRemote = True
    traceId <- get
    spanId <- get
    traceState <- get
    pure SpanContext{..}

renderTypedProtocolSelectorOTel
  :: forall ps. OTelProtocol ps => RenderSelectorOTel (TypedProtocolsSelector ps)
renderTypedProtocolSelectorOTel = \case
  ReceiveSelector tok msg -> OTelRendered
    { eventName = "receive " <> protocolName (Proxy @ps) <> ":" <> messageType (messageAttributes tok msg)
    , eventKind = Consumer
    , renderField = const []
    }
  CallSelector tok msg -> OTelRendered
    { eventName = "call " <> protocolName (Proxy @ps) <> ":" <> messageType (messageAttributes tok msg)
    , eventKind = Client
    , renderField = \case
        Nothing -> messageToAttributes "send" $ AnyMessageAndAgency tok msg
        Just msg' -> messageToAttributes "recv" msg'
    }
  RespondSelector tok msg -> OTelRendered
    { eventName = "respond " <> protocolName (Proxy @ps) <> ":" <> messageType (messageAttributes tok msg)
    , eventKind = Server
    , renderField = \case
        Nothing -> messageToAttributes "recv" $ AnyMessageAndAgency tok msg
        Just msg' -> messageToAttributes "send" msg'
    }
  CastSelector tok msg -> OTelRendered
    { eventName = "cast " <> protocolName (Proxy @ps) <> ":" <> messageType (messageAttributes tok msg)
    , eventKind = Producer
    , renderField = const []
    }
  CloseSelector tok msg -> OTelRendered
    { eventName = "close " <> protocolName (Proxy @ps) <> ":" <> messageType (messageAttributes tok msg)
    , eventKind = Producer
    , renderField = const []
    }

messageToAttributes :: Text -> OTelProtocol ps => AnyMessageAndAgency ps -> [(Text, Attribute)]
messageToAttributes prefix (AnyMessageAndAgency tok msg) = case messageAttributes tok msg of
  MessageAttributes{..} ->
    [ ("typed-protocols.message." <> prefix <> ".type", toAttribute messageType)
    , ("typed-protocols.message." <> prefix <> ".parameters", toAttribute messageParameters)
    ]