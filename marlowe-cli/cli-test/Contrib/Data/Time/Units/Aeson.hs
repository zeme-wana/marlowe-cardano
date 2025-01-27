{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NumericUnderscores #-}

module Contrib.Data.Time.Units.Aeson where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON))
import Data.Time.Units (TimeUnit)
import Data.Time.Units qualified as Time.Units
import GHC.Generics (Generic)

newtype Second = Second {toSecond :: Time.Units.Second}
  deriving stock (Eq, Generic, Show)

instance FromJSON Second where
  parseJSON json = do
    s <- parseJSON json
    pure $ Second . Time.Units.fromMicroseconds $ s * 1_000_000

instance ToJSON Second where
  toJSON (Second s) = do
    let micro = Time.Units.toMicroseconds s
    toJSON (micro `div` 1_000_000)

instance TimeUnit Second where
  toMicroseconds = Time.Units.toMicroseconds . toSecond
  fromMicroseconds = Second . Time.Units.fromMicroseconds

newtype Millisecond = Millisecond {toMillisecond :: Time.Units.Millisecond}
  deriving stock (Eq, Generic, Show)

instance FromJSON Millisecond where
  parseJSON json = do
    s <- parseJSON json
    pure $ Millisecond . Time.Units.fromMicroseconds $ s * 1_000

instance ToJSON Millisecond where
  toJSON (Millisecond s) = do
    let micro = Time.Units.toMicroseconds s
    toJSON (micro `div` 1_000)

instance TimeUnit Millisecond where
  toMicroseconds = Time.Units.toMicroseconds . toMillisecond
  fromMicroseconds = Millisecond . Time.Units.fromMicroseconds

newtype Microsecond = Microsecond {toMicrosecond :: Time.Units.Microsecond}
  deriving stock (Eq, Generic, Show)

instance FromJSON Microsecond where
  parseJSON json = do
    s <- parseJSON json
    pure $ Microsecond . Time.Units.fromMicroseconds $ s

instance ToJSON Microsecond where
  toJSON (Microsecond s) = do
    toJSON $ Time.Units.toMicroseconds s

instance TimeUnit Microsecond where
  toMicroseconds = Time.Units.toMicroseconds . toMicrosecond
  fromMicroseconds = Microsecond . Time.Units.fromMicroseconds
