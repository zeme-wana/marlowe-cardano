-----------------------------------------------------------------------------
--
-- Module      :  $Headers
-- License     :  Apache 2.0
--
-- Stability   :  Experimental
-- Portability :  Portable
--
-- | Types for the Marlowe CLI tool.
--
-----------------------------------------------------------------------------


{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}


module Language.Marlowe.CLI.Types (
-- * Marlowe Transactions
  MarloweTransaction(..)
, MarloweInfo(..)
, ValidatorInfo(..)
, DatumInfo(..)
, RedeemerInfo(..)
, SomeMarloweTransaction(..)
, CliEnv(..)
-- * eUTxOs
, PayFromScript(..)
, PayToScript(..)
-- * Keys
, SomePaymentVerificationKey
, SomePaymentSigningKey
-- * Exceptions
, CliError(..)
-- * Queries
, OutputQuery(..)
-- * Merklization
, Continuations
-- * pattern matching boilerplate
, withCardanoEra
, withShelleyBasedEra
, toAsType
, toEraInMode
, toShelleyBasedEra
, toPlutusScriptV1LanguageInEra
, toSimpleScriptV2LanguageInEra
, toTxMetadataSupportedInEra
, toMultiAssetSupportedInEra
, toTxScriptValiditySupportedInEra
, toCollateralSupportedInEra
, toTxFeesExplicitInEra
, toValidityLowerBoundSupportedInEra
, toValidityUpperBoundSupportedInEra
, toValidityNoUpperBoundSupportedInEra
, toExtraKeyWitnessesSupportedInEra
, askEra
, asksEra
, doWithCardanoEra
, doWithShelleyBasedEra
, toAddressAny'
) where


import Cardano.Api (AddressAny, AddressInEra (AddressInEra), AsType (..), AssetId, CardanoMode,
                    CollateralSupportedInEra (..), EraInMode (..), HasTypeProxy (proxyToAsType), Hash, IsCardanoEra,
                    IsShelleyBasedEra, Lovelace, MultiAssetSupportedInEra (..), PaymentExtendedKey, PaymentKey,
                    PlutusScript, PlutusScriptV1, PlutusScriptVersion (..), Script (..), ScriptData,
                    ScriptDataSupportedInEra (..), ScriptLanguageInEra (..), ShelleyBasedEra (..), SigningKey,
                    SimpleScriptV2, SlotNo, TxExtraKeyWitnessesSupportedInEra (..), TxFeesExplicitInEra (..), TxIn,
                    TxMetadataSupportedInEra (..), TxScriptValiditySupportedInEra (..),
                    ValidityLowerBoundSupportedInEra (..), ValidityNoUpperBoundSupportedInEra (..),
                    ValidityUpperBoundSupportedInEra (..), VerificationKey, deserialiseAddress,
                    deserialiseFromTextEnvelope, serialiseAddress, serialiseToTextEnvelope, toAddressAny)
import Cardano.Api.Shelley (PlutusScript (..))
import Codec.Serialise (deserialise)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.ByteString.Short (ShortByteString)
import Data.Maybe (fromMaybe)
import Data.String (IsString)
import GHC.Generics (Generic)
import Language.Marlowe.CLI.Orphans ()
import Language.Marlowe.Core.V1.Semantics (Payment)
import Language.Marlowe.Core.V1.Semantics.Types (Contract, Input, State)
import Ledger.Orphans ()
import Plutus.V1.Ledger.Api (CurrencySymbol, Datum, DatumHash, ExBudget, Redeemer, ValidatorHash)
import Plutus.V1.Ledger.SlotConfig (SlotConfig)

import qualified Cardano.Api as Api (Value)
import Control.Monad.Reader.Class (MonadReader (..), asks)
import qualified Data.ByteString.Lazy as LBS (fromStrict)
import qualified Data.ByteString.Short as SBS (fromShort)
import qualified Data.Map.Strict as M (Map)
import Data.Proxy (Proxy (Proxy))


-- | Exception for Marlowe CLI.
newtype CliError = CliError {unCliError :: String}
  deriving (Eq, IsString, Ord, Read, Show)


-- | A payment key.
type SomePaymentVerificationKey = Either (VerificationKey PaymentKey) (VerificationKey PaymentExtendedKey)


-- | A payment signing key.
type SomePaymentSigningKey = Either (SigningKey PaymentKey) (SigningKey PaymentExtendedKey)


-- | Continuations for contracts.
type Continuations = M.Map DatumHash Contract

-- | A marlowe transaction in an existentially quantified era
data SomeMarloweTransaction = forall era. SomeMarloweTransaction (ScriptDataSupportedInEra era) (MarloweTransaction era)

doWithCardanoEra :: forall era m a. MonadReader (CliEnv era) m => (IsCardanoEra era => m a) -> m a
doWithCardanoEra m = askEra >>= \era -> withCardanoEra era m

doWithShelleyBasedEra :: forall era m a. MonadReader (CliEnv era) m => (IsShelleyBasedEra era => m a) -> m a
doWithShelleyBasedEra m = askEra >>= \era -> withShelleyBasedEra era m

withCardanoEra :: forall era a. ScriptDataSupportedInEra era -> (IsCardanoEra era => a) -> a
withCardanoEra = \case
  ScriptDataInAlonzoEra  -> id
  ScriptDataInBabbageEra -> id

withShelleyBasedEra :: forall era a. ScriptDataSupportedInEra era -> (IsShelleyBasedEra era => a) -> a
withShelleyBasedEra = \case
  ScriptDataInAlonzoEra  -> id
  ScriptDataInBabbageEra -> id

toAsType :: ScriptDataSupportedInEra era -> AsType era
toAsType = \case
  ScriptDataInAlonzoEra  -> AsAlonzoEra
  ScriptDataInBabbageEra -> AsBabbageEra

toEraInMode :: ScriptDataSupportedInEra era -> EraInMode era CardanoMode
toEraInMode = \case
  ScriptDataInAlonzoEra  -> AlonzoEraInCardanoMode
  ScriptDataInBabbageEra -> BabbageEraInCardanoMode

toShelleyBasedEra :: ScriptDataSupportedInEra era -> ShelleyBasedEra era
toShelleyBasedEra = \case
  ScriptDataInAlonzoEra  -> ShelleyBasedEraAlonzo
  ScriptDataInBabbageEra -> ShelleyBasedEraBabbage

toPlutusScriptV1LanguageInEra :: ScriptDataSupportedInEra era -> ScriptLanguageInEra PlutusScriptV1 era
toPlutusScriptV1LanguageInEra = \case
  ScriptDataInAlonzoEra  -> PlutusScriptV1InAlonzo
  ScriptDataInBabbageEra -> PlutusScriptV1InBabbage

toSimpleScriptV2LanguageInEra :: ScriptDataSupportedInEra era -> ScriptLanguageInEra SimpleScriptV2 era
toSimpleScriptV2LanguageInEra = \case
  ScriptDataInAlonzoEra  -> SimpleScriptV2InAlonzo
  ScriptDataInBabbageEra -> SimpleScriptV2InBabbage

toTxMetadataSupportedInEra :: ScriptDataSupportedInEra era -> TxMetadataSupportedInEra era
toTxMetadataSupportedInEra = \case
  ScriptDataInAlonzoEra  -> TxMetadataInAlonzoEra
  ScriptDataInBabbageEra -> TxMetadataInBabbageEra

toMultiAssetSupportedInEra :: ScriptDataSupportedInEra era -> MultiAssetSupportedInEra era
toMultiAssetSupportedInEra = \case
  ScriptDataInAlonzoEra  -> MultiAssetInAlonzoEra
  ScriptDataInBabbageEra -> MultiAssetInBabbageEra

toTxScriptValiditySupportedInEra :: ScriptDataSupportedInEra era -> TxScriptValiditySupportedInEra era
toTxScriptValiditySupportedInEra = \case
  ScriptDataInAlonzoEra  -> TxScriptValiditySupportedInAlonzoEra
  ScriptDataInBabbageEra -> TxScriptValiditySupportedInBabbageEra

toCollateralSupportedInEra :: ScriptDataSupportedInEra era -> CollateralSupportedInEra era
toCollateralSupportedInEra = \case
  ScriptDataInAlonzoEra  -> CollateralInAlonzoEra
  ScriptDataInBabbageEra -> CollateralInBabbageEra

toTxFeesExplicitInEra :: ScriptDataSupportedInEra era -> TxFeesExplicitInEra era
toTxFeesExplicitInEra = \case
  ScriptDataInAlonzoEra  -> TxFeesExplicitInAlonzoEra
  ScriptDataInBabbageEra -> TxFeesExplicitInBabbageEra

toValidityLowerBoundSupportedInEra :: ScriptDataSupportedInEra era -> ValidityLowerBoundSupportedInEra era
toValidityLowerBoundSupportedInEra = \case
  ScriptDataInAlonzoEra  -> ValidityLowerBoundInAlonzoEra
  ScriptDataInBabbageEra -> ValidityLowerBoundInBabbageEra

toValidityUpperBoundSupportedInEra :: ScriptDataSupportedInEra era -> ValidityUpperBoundSupportedInEra era
toValidityUpperBoundSupportedInEra = \case
  ScriptDataInAlonzoEra  -> ValidityUpperBoundInAlonzoEra
  ScriptDataInBabbageEra -> ValidityUpperBoundInBabbageEra

toValidityNoUpperBoundSupportedInEra :: ScriptDataSupportedInEra era -> ValidityNoUpperBoundSupportedInEra era
toValidityNoUpperBoundSupportedInEra = \case
  ScriptDataInAlonzoEra  -> ValidityNoUpperBoundInAlonzoEra
  ScriptDataInBabbageEra -> ValidityNoUpperBoundInBabbageEra

toExtraKeyWitnessesSupportedInEra :: ScriptDataSupportedInEra era -> TxExtraKeyWitnessesSupportedInEra era
toExtraKeyWitnessesSupportedInEra = \case
  ScriptDataInAlonzoEra  -> ExtraKeyWitnessesInAlonzoEra
  ScriptDataInBabbageEra -> ExtraKeyWitnessesInBabbageEra

toAddressAny' :: AddressInEra era -> AddressAny
toAddressAny' (AddressInEra _ addr) = toAddressAny addr

newtype CliEnv era = CliEnv { era :: ScriptDataSupportedInEra era }

askEra :: MonadReader (CliEnv era) m => m (ScriptDataSupportedInEra era)
askEra = asks era

asksEra :: MonadReader (CliEnv era) m => (ScriptDataSupportedInEra era -> a) -> m a
asksEra f = f <$> askEra

instance ToJSON SomeMarloweTransaction where
  toJSON (SomeMarloweTransaction era tx) = withShelleyBasedEra era $ object
    let
      eraStr :: String
      eraStr = case era of
        ScriptDataInAlonzoEra  -> "alonzo"
        ScriptDataInBabbageEra -> "babbage"
    in
      [ "era" .= eraStr
      , "tx" .= tx
      ]

instance FromJSON SomeMarloweTransaction where
  parseJSON = withObject "SomeTransaction" $ \obj -> do
    eraStr :: String <- obj .: "era"
    case eraStr of
      "alonzo"  -> SomeMarloweTransaction ScriptDataInAlonzoEra <$> obj .: "tx"
      "babbage" -> SomeMarloweTransaction ScriptDataInBabbageEra <$> obj .: "tx"
      _         -> fail $ "Unsupported era " <> show eraStr


-- | Complete description of a Marlowe transaction.
data MarloweTransaction era =
  MarloweTransaction
  {
    mtValidator     :: ValidatorInfo era       -- ^ The Marlowe validator.
  , mtRoleValidator :: ValidatorInfo era       -- ^ The roles validator.
  , mtRoles         :: CurrencySymbol          -- ^ The roles currency.
  , mtState         :: State                   -- ^ The Marlowe state after the transaction.
  , mtContract      :: Contract                -- ^ The Marlowe contract after the transaction.
  , mtContinuations :: Continuations           -- ^ The merkleized continuations for the contract.
  , mtRange         :: Maybe (SlotNo, SlotNo)  -- ^ The slot range for the transaction, if any.
  , mtInputs        :: [Input]                 -- ^ The inputs to the transaction.
  , mtPayments      :: [Payment]               -- ^ The payments from the transaction.
  , mtSlotConfig    :: SlotConfig              -- ^ The POSIXTime-to-Slot configuration.
  }
    deriving (Generic, Show)

instance IsShelleyBasedEra era => ToJSON (MarloweTransaction era) where
  toJSON MarloweTransaction{..} =
    object
      [
        "marloweValidator" .= toJSON mtValidator
      , "rolesValidator"   .= toJSON mtRoleValidator
      , "roles"            .= toJSON mtRoles
      , "state"            .= toJSON mtState
      , "contract"         .= toJSON mtContract
      , "continuations"    .= toJSON mtContinuations
      , "range"            .= toJSON mtRange
      , "inputs"           .= toJSON mtInputs
      , "payments"         .= toJSON mtPayments
      , "slotConfig"       .= toJSON mtSlotConfig
      ]

instance IsShelleyBasedEra era => FromJSON (MarloweTransaction era) where
  parseJSON =
    withObject "MarloweTransaction"
      $ \o ->
        do
          mtValidator     <- o .: "marloweValidator"
          mtRoleValidator <- o .: "rolesValidator"
          mtRoles         <- o .: "roles"
          mtState         <- o .: "state"
          mtContract      <- o .: "contract"
          mtContinuations <- fromMaybe mempty <$> (o .:? "continuations")
          mtRange         <- o .: "range"
          mtInputs        <- o .: "inputs"
          mtPayments      <- o .: "payments"
          mtSlotConfig    <- o .: "slotConfig"
          pure MarloweTransaction{..}


-- | Comprehensive information about a Marlowe transaction.
data MarloweInfo era =
  MarloweInfo
  {
    validatorInfo :: ValidatorInfo era  -- ^ Validator information.
  , datumInfo     :: DatumInfo          -- ^ Datum information.
  , redeemerInfo  :: RedeemerInfo       -- ^ Redeemer information.
  }
    deriving (Eq, Generic, Show)

instance IsShelleyBasedEra era => ToJSON (MarloweInfo era) where
  toJSON MarloweInfo{..} =
    object
      [
        "validator" .= toJSON validatorInfo
      , "datum"     .= toJSON datumInfo
      , "redeemer"  .= toJSON redeemerInfo
      ]

instance IsShelleyBasedEra era => FromJSON (MarloweInfo era) where
  parseJSON =
    withObject "MarloweInfo"
      $ \o ->
        do
          validatorInfo <- o .: "validator"
          datumInfo     <- o .: "datum"
          redeemerInfo  <- o .: "redeemer"
          pure MarloweInfo{..}


-- | Information about Marlowe validator.
data ValidatorInfo era =
  ValidatorInfo
  {
    viScript  :: Script PlutusScriptV1       -- ^ The Plutus script.
  , viBytes   :: ShortByteString             -- ^ The serialisation of the validator.
  , viHash    :: ValidatorHash               -- ^ The validator hash.
  , viAddress :: AddressInEra era            -- ^ The script address.
  , viSize    :: Int                         -- ^ The script size, in bytes.
  , viCost    :: ExBudget                    -- ^ The execution budget for the script.
  }
    deriving (Eq, Generic, Show)

instance IsShelleyBasedEra era => ToJSON (ValidatorInfo era) where
  toJSON ValidatorInfo{..} =
    object
      [
        "address" .= serialiseAddress viAddress
      , "hash"    .= toJSON viHash
      , "script"  .= toJSON (serialiseToTextEnvelope Nothing viScript)
      , "size"    .= toJSON viSize
      , "cost"    .= toJSON viCost
      ]

instance IsShelleyBasedEra era => FromJSON (ValidatorInfo era) where
  parseJSON =
    withObject "ValidatorInfo"
      $ \o ->
        do
          address   <- o .: "address"
          viHash    <- o .: "hash"
          script    <- o .: "script"
          viSize    <- o .: "size"
          viCost    <- o .: "cost"
          viAddress <- case deserialiseAddress (proxyToAsType (Proxy :: Proxy (AddressInEra era))) address of
                         Just address' -> pure address'
                         Nothing       -> fail "Failed deserialising address."
          viScript <- case deserialiseFromTextEnvelope (AsScript AsPlutusScriptV1) script of
                         Right script' -> pure script'
                         Left message  -> fail $ show message
          let
            PlutusScript PlutusScriptV1 (PlutusScriptSerialised viBytes) = viScript
          pure ValidatorInfo{..}


-- | Information about Marlowe datum.
data DatumInfo =
  DatumInfo
  {
    diDatum :: Datum            -- ^ The datum.
  , diBytes :: ShortByteString  -- ^ The serialisation of the datum.
  , diJson  :: Value            -- ^ The JSON representation of the datum.
  , diHash  :: DatumHash        -- ^ The hash of the datum.
  , diSize  :: Int              -- ^ The size of the datum, in bytes.
  }
    deriving (Eq, Generic, Show)

instance ToJSON DatumInfo where
  toJSON DatumInfo{..} =
    object
      [
        "hash"    .= toJSON diHash
      , "cborHex" .= toJSON diBytes
      , "json"    .=        diJson
      , "size"    .= toJSON diSize
      ]

instance FromJSON DatumInfo where
  parseJSON =
    withObject "DatumInfo"
      $ \o ->
        do
          diHash  <- o .: "hash"
          diBytes <- o .: "cboxHex"
          diJson  <- o .: "json"
          diSize  <- o .: "size"
          let
            diDatum = deserialise . LBS.fromStrict $ SBS.fromShort diBytes
          pure DatumInfo{..}


-- | Information about Marlowe redeemer.
data RedeemerInfo =
  RedeemerInfo
  {
    riRedeemer :: Redeemer         -- ^ The redeemer.
  , riBytes    :: ShortByteString  -- ^ The serialisation of the redeemer.
  , riJson     :: Value            -- ^ The JSON representation of the redeemer.
  , riSize     :: Int              -- ^ The size of the redeemer, in bytes.
  }
    deriving (Eq, Generic, Show)

instance ToJSON RedeemerInfo where
  toJSON RedeemerInfo{..} =
    object
      [
        "cboxHex" .= toJSON riBytes
      , "json"    .=        riJson
      , "size"    .= toJSON riSize
      ]

instance FromJSON RedeemerInfo where
  parseJSON =
    withObject "RedeemerInfo"
      $ \o ->
        do
          riBytes <- o .: "cboxHex"
          riJson  <- o .: "json"
          riSize  <- o .: "size"
          let
            riRedeemer = deserialise . LBS.fromStrict $ SBS.fromShort riBytes
          pure RedeemerInfo{..}


-- | Information required to spend from a script.
data PayFromScript =
  PayFromScript
  {
    txIn     :: TxIn                         -- ^ The eUTxO to be spent.
  , script   :: PlutusScript PlutusScriptV1  -- ^ The script.
  , datum    :: Datum                        -- ^ The datum.
  , redeemer :: Redeemer                     -- ^ The redeemer.
  }
    deriving (Eq, Generic, Show)


-- | Information required to pay to a script.
data PayToScript era =
  PayToScript
  {
    address   :: AddressInEra era  -- ^ The script address.
  , value     :: Api.Value         -- ^ The value to be paid.
  , datumOut  :: ScriptData        -- ^ The datum.
  , datumHash :: Hash ScriptData   -- ^ The datum hash.
  }
    deriving (Eq, Generic, Show)


-- | Options for address queries.
data OutputQuery =
    -- | Return all UTxOs.
    AllOutput
    -- | Only return pure-ADA UTxOs with at least the specified amount.
  | LovelaceOnly
    {
      lovelace :: Lovelace
    }
    -- | Only require UTxOs containing only the specified asset.
  | AssetOnly
    {
      asset :: AssetId
    }