-- File auto generated by purescript-bridge! --
module Plutus.PAB.Events.ContractInstanceState where

import Prelude

import Control.Lazy (defer)
import Control.Monad.Freer.Extras.Log (LogMessage)
import Data.Argonaut.Core (jsonNull)
import Data.Argonaut.Decode (class DecodeJson)
import Data.Argonaut.Decode.Aeson ((</$\>), (</*\>), (</\>))
import Data.Argonaut.Decode.Aeson as D
import Data.Argonaut.Encode (class EncodeJson, encodeJson)
import Data.Argonaut.Encode.Aeson ((>$<), (>/\<))
import Data.Argonaut.Encode.Aeson as E
import Data.Generic.Rep (class Generic)
import Data.Lens (Iso', Lens', Prism', iso, prism')
import Data.Lens.Iso.Newtype (_Newtype)
import Data.Lens.Record (prop)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, unwrap)
import Data.RawJson (RawJson)
import Data.Show.Generic (genericShow)
import Data.Tuple.Nested ((/\))
import Plutus.Contract.Resumable (Request)
import Type.Proxy (Proxy(Proxy))

newtype PartiallyDecodedResponse a = PartiallyDecodedResponse
  { hooks :: Array (Request a)
  , logs :: Array (LogMessage RawJson)
  , lastLogs :: Array (LogMessage RawJson)
  , err :: Maybe RawJson
  , observableState :: RawJson
  }

derive instance eqPartiallyDecodedResponse ::
  ( Eq a
  ) =>
  Eq (PartiallyDecodedResponse a)

instance showPartiallyDecodedResponse ::
  ( Show a
  ) =>
  Show (PartiallyDecodedResponse a) where
  show a = genericShow a

instance encodeJsonPartiallyDecodedResponse ::
  ( EncodeJson a
  ) =>
  EncodeJson (PartiallyDecodedResponse a) where
  encodeJson = defer \_ -> E.encode $ unwrap >$<
    ( E.record
        { hooks: E.value :: _ (Array (Request a))
        , logs: E.value :: _ (Array (LogMessage RawJson))
        , lastLogs: E.value :: _ (Array (LogMessage RawJson))
        , err: (E.maybe E.value) :: _ (Maybe RawJson)
        , observableState: E.value :: _ RawJson
        }
    )

instance decodeJsonPartiallyDecodedResponse ::
  ( DecodeJson a
  ) =>
  DecodeJson (PartiallyDecodedResponse a) where
  decodeJson = defer \_ -> D.decode $
    ( PartiallyDecodedResponse <$> D.record "PartiallyDecodedResponse"
        { hooks: D.value :: _ (Array (Request a))
        , logs: D.value :: _ (Array (LogMessage RawJson))
        , lastLogs: D.value :: _ (Array (LogMessage RawJson))
        , err: (D.maybe D.value) :: _ (Maybe RawJson)
        , observableState: D.value :: _ RawJson
        }
    )

derive instance genericPartiallyDecodedResponse ::
  Generic (PartiallyDecodedResponse a) _

derive instance newtypePartiallyDecodedResponse ::
  Newtype (PartiallyDecodedResponse a) _

--------------------------------------------------------------------------------

_PartiallyDecodedResponse
  :: forall a
   . Iso' (PartiallyDecodedResponse a)
       { hooks :: Array (Request a)
       , logs :: Array (LogMessage RawJson)
       , lastLogs :: Array (LogMessage RawJson)
       , err :: Maybe RawJson
       , observableState :: RawJson
       }
_PartiallyDecodedResponse = _Newtype