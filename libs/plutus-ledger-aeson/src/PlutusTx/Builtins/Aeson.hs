{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module PlutusTx.Builtins.Aeson where

import PlutusCore.Data.Aeson ()
import PlutusTx.Prelude qualified as PlutusTx

import Data.ByteString.Base16.Aeson (EncodeBase16 (..))
import Data.ByteString.Base16.Aeson as Base16.Aeson

import Codec.Serialise (Serialise (decode, encode))
import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON))
import Data.Aeson qualified as JSON
import Data.Functor qualified
import PlutusCore.Data
import PlutusTx qualified
import PlutusTx.Builtins.Internal (BuiltinData (..))

instance ToJSON PlutusTx.BuiltinByteString where
  toJSON = Base16.Aeson.byteStringToJSON . PlutusTx.fromBuiltin

instance FromJSON PlutusTx.BuiltinByteString where
  parseJSON v = do
    EncodeBase16 bs <- parseJSON v
    pure $ PlutusTx.toBuiltin bs

instance ToJSON PlutusTx.BuiltinData where
  toJSON = toJSON . PlutusTx.builtinDataToData

instance FromJSON PlutusTx.BuiltinData where
  parseJSON v = parseJSON v Data.Functor.<&> PlutusTx.dataToBuiltinData

instance Serialise PlutusTx.BuiltinData where
  encode = encode . PlutusTx.builtinDataToData
  decode = PlutusTx.dataToBuiltinData <$> decode
