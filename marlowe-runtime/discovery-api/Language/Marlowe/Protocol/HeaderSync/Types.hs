{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

module Language.Marlowe.Protocol.HeaderSync.Types where

import Control.Monad (join)
import Data.Aeson (Value (..), object, (.=))
import Data.Binary (get, put, putWord8)
import Data.Binary.Get (getWord8)
import qualified Data.List.NonEmpty as NE
import Data.String (fromString)
import GHC.Show (showSpace)
import Language.Marlowe.Runtime.ChainSync.Api (BlockHeader, ChainPoint)
import Language.Marlowe.Runtime.Discovery.Api (ContractHeader)
import Network.Protocol.Codec (BinaryMessage (..))
import Network.Protocol.Codec.Spec (
  MessageEq (..),
  MessageVariations (..),
  ShowProtocol (..),
  SomePeerHasAgency (..),
  Variations (..),
  varyAp,
 )
import Network.Protocol.Handshake.Types (HasSignature (..))
import Network.Protocol.Peer.Trace
import Network.TypedProtocol (PeerHasAgency (..), Protocol (..))
import Network.TypedProtocol.Codec (AnyMessageAndAgency (AnyMessageAndAgency), SomeMessage (..))
import Observe.Event.Network.Protocol (MessageToJSON (..))
import OpenTelemetry.Attributes

data MarloweHeaderSync where
  StIdle :: MarloweHeaderSync
  StIntersect :: MarloweHeaderSync
  StNext :: MarloweHeaderSync
  StWait :: MarloweHeaderSync
  StDone :: MarloweHeaderSync

instance HasSignature MarloweHeaderSync where
  signature _ = "MarloweHeaderSync"

instance Protocol MarloweHeaderSync where
  data Message MarloweHeaderSync from to where
    MsgIntersect
      :: [BlockHeader]
      -> Message
          MarloweHeaderSync
          'StIdle
          'StIntersect
    MsgDone
      :: Message
          MarloweHeaderSync
          'StIdle
          'StDone
    MsgRequestNext
      :: Message
          MarloweHeaderSync
          'StIdle
          'StNext
    MsgNewHeaders
      :: BlockHeader
      -> [ContractHeader]
      -> Message
          MarloweHeaderSync
          'StNext
          'StIdle
    MsgRollBackward
      :: ChainPoint
      -> Message
          MarloweHeaderSync
          'StNext
          'StIdle
    MsgWait
      :: Message
          MarloweHeaderSync
          'StNext
          'StWait
    MsgPoll
      :: Message
          MarloweHeaderSync
          'StWait
          'StNext
    MsgCancel
      :: Message
          MarloweHeaderSync
          'StWait
          'StIdle
    MsgIntersectFound
      :: BlockHeader
      -> Message
          MarloweHeaderSync
          'StIntersect
          'StIdle
    MsgIntersectNotFound
      :: Message
          MarloweHeaderSync
          'StIntersect
          'StIdle

  data ClientHasAgency st where
    TokIdle :: ClientHasAgency 'StIdle
    TokWait :: ClientHasAgency 'StWait

  data ServerHasAgency st where
    TokNext :: ServerHasAgency 'StNext
    TokIntersect :: ServerHasAgency 'StIntersect

  data NobodyHasAgency st where
    TokDone :: NobodyHasAgency 'StDone

  exclusionLemma_ClientAndServerHaveAgency TokIdle = \case {}
  exclusionLemma_ClientAndServerHaveAgency TokWait = \case {}

  exclusionLemma_NobodyAndClientHaveAgency TokDone = \case {}

  exclusionLemma_NobodyAndServerHaveAgency TokDone = \case {}

instance BinaryMessage MarloweHeaderSync where
  putMessage = \case
    ClientAgency TokIdle -> \case
      MsgRequestNext -> putWord8 0x01
      MsgIntersect blocks -> putWord8 0x02 *> put blocks
      MsgDone -> putWord8 0x03
    ServerAgency TokNext -> \case
      MsgNewHeaders block headers -> do
        putWord8 0x04
        put block
        put headers
      MsgRollBackward block -> do
        putWord8 0x05
        put block
      MsgWait -> putWord8 0x06
    ClientAgency TokWait -> \case
      MsgPoll -> putWord8 0x07
      MsgCancel -> putWord8 0x08
    ServerAgency TokIntersect -> \case
      MsgIntersectFound block -> do
        putWord8 0x09
        put block
      MsgIntersectNotFound -> putWord8 0x0a

  getMessage tok = do
    tag <- getWord8
    case tag of
      0x01 -> case tok of
        ClientAgency TokIdle -> pure $ SomeMessage MsgRequestNext
        _ -> fail "Invalid protocol state for MsgRequestNext"
      0x02 -> case tok of
        ClientAgency TokIdle -> SomeMessage . MsgIntersect <$> get
        _ -> fail "Invalid protocol state for MsgNewHeaders"
      0x03 -> case tok of
        ClientAgency TokIdle -> pure $ SomeMessage MsgDone
        _ -> fail "Invalid protocol state for MsgDone"
      0x04 -> case tok of
        ServerAgency TokNext -> do
          block <- get
          SomeMessage . MsgNewHeaders block <$> get
        _ -> fail "Invalid protocol state for MsgNewHeaders"
      0x05 -> case tok of
        ServerAgency TokNext -> SomeMessage . MsgRollBackward <$> get
        _ -> fail "Invalid protocol state for MsgRollBackward"
      0x06 -> case tok of
        ServerAgency TokNext -> pure $ SomeMessage MsgWait
        _ -> fail "Invalid protocol state for MsgWait"
      0x07 -> case tok of
        ClientAgency TokWait -> pure $ SomeMessage MsgPoll
        _ -> fail "Invalid protocol state for MsgPoll"
      0x08 -> case tok of
        ClientAgency TokWait -> pure $ SomeMessage MsgCancel
        _ -> fail "Invalid protocol state for MsgCancel"
      0x09 -> case tok of
        ServerAgency TokIntersect -> SomeMessage . MsgIntersectFound <$> get
        _ -> fail "Invalid protocol state for MsgIntersectFound"
      0x0a -> case tok of
        ServerAgency TokIntersect -> pure $ SomeMessage MsgIntersectNotFound
        _ -> fail "Invalid protocol state for MsgIntersectNotFound"
      _ -> fail $ "Invalid message tag " <> show tag

instance MessageVariations MarloweHeaderSync where
  agencyVariations =
    NE.fromList
      [ SomePeerHasAgency $ ClientAgency TokIdle
      , SomePeerHasAgency $ ClientAgency TokWait
      , SomePeerHasAgency $ ServerAgency TokNext
      , SomePeerHasAgency $ ServerAgency TokIntersect
      ]
  messageVariations = \case
    ClientAgency TokIdle -> NE.fromList [SomeMessage MsgDone, SomeMessage MsgRequestNext]
    ClientAgency TokWait -> NE.fromList [SomeMessage MsgPoll, SomeMessage MsgCancel]
    ServerAgency TokNext ->
      join $
        NE.fromList
          [ fmap SomeMessage $ MsgNewHeaders <$> variations `varyAp` variations
          , SomeMessage . MsgRollBackward <$> variations
          , pure $ SomeMessage MsgWait
          ]
    ServerAgency TokIntersect ->
      join $
        NE.fromList
          [ SomeMessage . MsgIntersectFound <$> variations
          , pure $ SomeMessage MsgIntersectNotFound
          ]

instance MessageToJSON MarloweHeaderSync where
  messageToJSON = \case
    ClientAgency TokIdle -> \case
      MsgDone -> String "done"
      MsgRequestNext -> String "request-next"
      MsgIntersect headers -> object ["intersect" .= headers]
    ClientAgency TokWait -> \case
      MsgPoll -> String "poll"
      MsgCancel -> String "cancel"
    ServerAgency TokNext -> \case
      MsgNewHeaders blockHeader headers ->
        object
          [ "new-headers"
              .= object
                [ "block-header" .= blockHeader
                , "contract-headers" .= headers
                ]
          ]
      MsgRollBackward blockHeader -> object ["roll-backward" .= blockHeader]
      MsgWait -> String "wait"
    ServerAgency TokIntersect -> \case
      MsgIntersectFound blockHeader -> object ["intersect-found" .= blockHeader]
      MsgIntersectNotFound -> String "intersect-not-found"

instance MessageEq MarloweHeaderSync where
  messageEq = \case
    AnyMessageAndAgency _ (MsgIntersect points) -> \case
      AnyMessageAndAgency _ (MsgIntersect points') -> points == points'
      _ -> False
    AnyMessageAndAgency _ MsgDone -> \case
      AnyMessageAndAgency _ MsgDone -> True
      _ -> False
    AnyMessageAndAgency _ MsgRequestNext -> \case
      AnyMessageAndAgency _ MsgRequestNext -> True
      _ -> False
    AnyMessageAndAgency agency (MsgNewHeaders blockHeader headers) -> \case
      AnyMessageAndAgency agency' (MsgNewHeaders blockHeader' contractSteps') ->
        blockHeader == blockHeader' && case (agency, agency') of
          (ServerAgency TokNext, ServerAgency TokNext) -> headers == contractSteps'
      _ -> False
    AnyMessageAndAgency _ (MsgRollBackward point) -> \case
      AnyMessageAndAgency _ (MsgRollBackward point') -> point == point'
      _ -> False
    AnyMessageAndAgency _ MsgWait -> \case
      AnyMessageAndAgency _ MsgWait -> True
      _ -> False
    AnyMessageAndAgency _ MsgPoll -> \case
      AnyMessageAndAgency _ MsgPoll -> True
      _ -> False
    AnyMessageAndAgency _ MsgCancel -> \case
      AnyMessageAndAgency _ MsgCancel -> True
      _ -> False
    AnyMessageAndAgency _ (MsgIntersectFound point) -> \case
      AnyMessageAndAgency _ (MsgIntersectFound point') -> point == point'
      _ -> False
    AnyMessageAndAgency _ MsgIntersectNotFound -> \case
      AnyMessageAndAgency _ MsgIntersectNotFound -> True
      _ -> False

instance OTelProtocol MarloweHeaderSync where
  protocolName _ = "marlowe_header_sync"
  messageAttributes = \case
    ClientAgency tok -> case tok of
      TokIdle -> \case
        MsgRequestNext ->
          MessageAttributes
            { messageType = "request_next"
            , messageParameters = []
            }
        MsgIntersect blocks ->
          MessageAttributes
            { messageType = "intersect"
            , messageParameters = TextAttribute . fromString . show <$> blocks
            }
        MsgDone ->
          MessageAttributes
            { messageType = "done"
            , messageParameters = []
            }
      TokWait -> \case
        MsgPoll ->
          MessageAttributes
            { messageType = "poll"
            , messageParameters = []
            }
        MsgCancel ->
          MessageAttributes
            { messageType = "cancel"
            , messageParameters = []
            }
    ServerAgency tok -> case tok of
      TokNext -> \case
        MsgNewHeaders block headers ->
          MessageAttributes
            { messageType = "request_next/new_headers"
            , messageParameters =
                TextAttribute
                  <$> [fromString $ show block, fromString $ show headers]
            }
        MsgRollBackward block ->
          MessageAttributes
            { messageType = "request_next/roll_backward"
            , messageParameters = TextAttribute <$> [fromString $ show block]
            }
        MsgWait ->
          MessageAttributes
            { messageType = "request_next/wait"
            , messageParameters = []
            }
      TokIntersect -> \case
        MsgIntersectFound block ->
          MessageAttributes
            { messageType = "intersect/found"
            , messageParameters = TextAttribute <$> [fromString $ show block]
            }
        MsgIntersectNotFound ->
          MessageAttributes
            { messageType = "intersect/not_found"
            , messageParameters = []
            }

instance ShowProtocol MarloweHeaderSync where
  showsPrecMessage p agency = \case
    MsgIntersect points ->
      showParen
        (p >= 11)
        ( showString "MsgIntersect"
            . showSpace
            . showsPrec 11 points
        )
    MsgDone -> showString "MsgDone"
    MsgRequestNext -> showString "MsgRequestNext"
    MsgNewHeaders blockHeader headers ->
      showParen
        (p >= 11)
        ( showString "MsgNewHeaders"
            . showSpace
            . showsPrec 11 blockHeader
            . showSpace
            . case agency of ServerAgency TokNext -> showsPrec 11 headers
        )
    MsgRollBackward point ->
      showParen
        (p >= 11)
        ( showString "MsgRollBackward"
            . showSpace
            . showsPrec 11 point
        )
    MsgWait -> showString "MsgWait"
    MsgPoll -> showString "MsgPoll"
    MsgCancel -> showString "MsgCancel"
    MsgIntersectFound point ->
      showParen
        (p >= 11)
        ( showString "MsgIntersectFound"
            . showSpace
            . showsPrec 11 point
        )
    MsgIntersectNotFound -> showString "MsgIntersectNotFound"

  showsPrecServerHasAgency _ =
    showString . \case
      TokNext -> "TokNext"
      TokIntersect -> "TokIntersect"

  showsPrecClientHasAgency _ =
    showString . \case
      TokIdle -> "TokIdle"
      TokWait -> "TokWait"
