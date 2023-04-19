
{-# LANGUAGE OverloadedStrings #-}


module Language.Marlowe.Runtime.Transaction.SafetySpec
  where


import Data.List (isInfixOf, nub)
import Data.Maybe (fromJust)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Language.Marlowe.Analysis.Safety.Types
import Language.Marlowe.Runtime.Core.Api (MarloweVersion(MarloweV1))
import Language.Marlowe.Runtime.Core.ScriptRegistry (MarloweScripts(..), getCurrentScripts)
import Language.Marlowe.Runtime.Transaction.Api (Mint(..), RoleTokensConfig(..))
import Language.Marlowe.Runtime.Transaction.BuildConstraintsSpec ()
import Language.Marlowe.Runtime.Transaction.Constraints (MarloweContext(..), solveConstraints)
import Language.Marlowe.Runtime.Transaction.ConstraintsSpec (protocolTestnet)
import Language.Marlowe.Runtime.Transaction.Safety
import Spec.Marlowe.Reference
import Spec.Marlowe.Semantics.Arbitrary ()
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck (counterexample, discard, elements, generate, ioProperty, sublistOf, suchThat, (===))

import qualified Cardano.Api as Cardano
import qualified Cardano.Api.Shelley as Shelley
import qualified Data.Map.Strict as M
import qualified Language.Marlowe.Core.V1.Semantics.Types as V1
import qualified Language.Marlowe.Runtime.Cardano.Api as Chain
import qualified Language.Marlowe.Runtime.ChainSync.Api as Chain hiding (toCardanoAddressAny)
import qualified Plutus.V2.Ledger.Api as Plutus
import qualified PlutusTx.Builtins as Plutus


spec :: Spec
spec =
  do

    let
      version = MarloweV1
      continuations = noContinuations version
      party = V1.Role "x"
      payee = V1.Party party
      payToken token = V1.Pay party payee token $ V1.Constant 1
      payRole role = V1.Pay (V1.Role role) (V1.Party $ V1.Role role) (V1.Token "" "") $ V1.Constant 1
      same x y = nub x == x && nub y == y && not (any (`notElem` x) y) && not (any (`notElem` y) x)

    describe "minAdaUpperBound"
      $ do
          let
          prop "At least Cardano.Api" $ \(address, hash, assets@(Chain.Assets _ tokens')) ->
            do
              let
                value = fromJust $ Chain.assetsToCardanoValue assets
                toToken (Chain.AssetId (Chain.PolicyId p) (Chain.TokenName n)) =
                  V1.Token
                    (Plutus.CurrencySymbol $ Plutus.toBuiltin p)
                    (Plutus.TokenName $ Plutus.toBuiltin n)
                tokens = fmap toToken . M.keys $ Chain.unTokens tokens'
                expected =
                  either (const 0) Cardano.selectLovelace
                    $ Cardano.calculateMinimumUTxO
                        Cardano.ShelleyBasedEraBabbage
                        (
                          Cardano.TxOut
                            (Cardano.anyAddressInShelleyBasedEra . fromJust $ Chain.toCardanoAddressAny address)
                            (Cardano.TxOutValue Cardano.MultiAssetInBabbageEra value)
                            (Cardano.TxOutDatumHash Cardano.ScriptDataInBabbageEra . fromJust $ Chain.toCardanoDatumHash hash)
                            Shelley.ReferenceScriptNone
                        )
                        protocolTestnet
                   :: Cardano.Lovelace
                contract = foldr payToken V1.Close tokens  -- The tokens just need to appear somewhere in the contract.
                actual = fromJust $ minAdaUpperBound protocolTestnet version contract continuations :: Cardano.Lovelace
              counterexample ("Expected minUTxO = " <> show expected)
                $ counterexample ("Actual minUTxO = " <> show actual)
                $ actual >= expected

    describe "checkContract"
      $ do
        prop "Contract without roles" $ \roleTokensConfig ->
          let
            contract = V1.Close
            actual = checkContract roleTokensConfig version contract continuations
          in
            counterexample ("Contract = " <> show contract)
              $ case roleTokensConfig of
                  RoleTokensNone -> actual === []
                  _              -> actual === [ContractHasNoRoles]
        prop "Contract with roles from minting" $ \roleTokensConfig ->
          case roleTokensConfig of
            RoleTokensMint mint ->
              let
                roles = Plutus.TokenName . Plutus.toBuiltin . Chain.unTokenName <$> M.keys (unMint mint)
                contract = foldr payRole V1.Close roles
                actual = checkContract roleTokensConfig version contract continuations
              in
                counterexample ("Contract = " <> show contract)
                  $ actual === mempty
            _ -> discard
        prop "Contract with roles missing from minting" $ \roleTokensConfig extra ->
          case roleTokensConfig of
            RoleTokensMint mint ->
              let
                roles = Plutus.TokenName . Plutus.toBuiltin . Chain.unTokenName <$> M.keys (unMint mint)
                contract = foldr payRole V1.Close $ extra <> roles
                actual = checkContract roleTokensConfig version contract continuations
                expected =
                  (MissingRoleToken <$> nub extra)
                    <> [RoleNameTooLong role | role@(Plutus.TokenName name) <- nub extra, Plutus.lengthOfByteString name > 32]
              in
                counterexample ("Contract = " <> show contract)
                  . counterexample ("Actual = " <> show actual)
                  . counterexample ("Expected = " <> show expected)
                  $ actual `same` expected
            _ -> discard
        prop "Contract with extra roles for minting" $ \roleTokensConfig ->
          case roleTokensConfig of
            RoleTokensMint mint ->
              do
                let
                  roles' = Plutus.TokenName . Plutus.toBuiltin . Chain.unTokenName <$> M.keys (unMint mint)
                roles <- sublistOf roles' `suchThat` (not . null)
                let
                  extra = filter (`notElem` roles) roles'
                  contract = foldr payRole V1.Close roles
                  actual = checkContract roleTokensConfig version contract continuations
                  expected = ExtraRoleToken <$> extra
                pure
                  . counterexample ("Contract = " <> show contract)
                  . counterexample ("Actual = " <> show actual)
                  . counterexample ("Expected = " <> show expected)
                  $ actual `same` expected
            _ -> discard
        prop "Contract with role name too long" $ \roles ->
          let
            contract = foldr payRole V1.Close roles
            actual = checkContract (RoleTokensUsePolicy "") version contract continuations
            expected =
              if null roles
                then [ContractHasNoRoles]
                else [RoleNameTooLong role | role@(Plutus.TokenName name) <- nub roles, Plutus.lengthOfByteString name > 32]
          in
            counterexample ("Contract = " <> show contract)
              . counterexample ("Actual = " <> show actual)
              . counterexample ("Expected = " <> show expected)
              $ actual `same` expected
        prop "Contract with illegal token" $ \tokens ->
          let
            contract = foldr payToken V1.Close tokens
            actual = checkContract (RoleTokensUsePolicy "") version contract continuations
            expected =
              if contract == V1.Close
                then [ContractHasNoRoles]
                else nub
                     [
                       if badToken
                         then InvalidToken token
                         else if badCurrency
                                then InvalidCurrencySymbol symbol
                                else TokenNameTooLong name
                     |
                       token@(V1.Token symbol@(Plutus.CurrencySymbol symbol') name@(Plutus.TokenName name')) <- nub tokens
                     , let ada = symbol' == "" && name' == ""
                     , let badToken = symbol' == "" && name' /= ""
                     , let badCurrency = Plutus.lengthOfByteString symbol' /= 28
                     , let badName = Plutus.lengthOfByteString name' > 32
                     , not ada
                     , badToken || badCurrency || badName
                     ]
          in
            counterexample ("Contract = " <> show contract)
              . counterexample ("Actual = " <> show actual)
              . counterexample ("Expected = " <> show expected)
              $ actual `same` expected

    describe "checkTransactions"
      $ do
        referenceContracts <- runIO $ readReferenceContracts' "../marlowe-test/reference/data"
        let
          zeroTime = posixSecondsToUTCTime 0
          (systemStart, eraHistory) = makeSystemHistory zeroTime
          solveConstraints' = solveConstraints systemStart eraHistory protocolTestnet
          networkId = Cardano.Testnet $ Cardano.NetworkMagic 1
          MarloweScripts{..} = getCurrentScripts version
          stakeReference = Shelley.NoStakeAddress
          marloweContext =
            MarloweContext
            {
              scriptOutput = Nothing
            , payoutOutputs = mempty
            , marloweAddress = Chain.fromCardanoAddressInEra Cardano.BabbageEra
                                 . Cardano.AddressInEra (Cardano.ShelleyAddressInEra Cardano.ShelleyBasedEraBabbage)
                                 $ Cardano.makeShelleyAddress
                                     networkId
                                     (fromJust . Chain.toCardanoPaymentCredential $ Chain.ScriptCredential marloweScript)
                                     stakeReference
            , payoutAddress = Chain.fromCardanoAddressInEra Cardano.BabbageEra
                                . Cardano.AddressInEra (Cardano.ShelleyAddressInEra Cardano.ShelleyBasedEraBabbage)
                                $ Cardano.makeShelleyAddress
                                    networkId
                                    (fromJust . Chain.toCardanoPaymentCredential $ Chain.ScriptCredential payoutScript)
                                    Cardano.NoStakeAddress
            , marloweScriptUTxO = fromJust $ M.lookup networkId marloweScriptUTxOs
            , payoutScriptUTxO = fromJust $ M.lookup networkId payoutScriptUTxOs
            , marloweScriptHash = marloweScript
            , payoutScriptHash = payoutScript
            }
        prop "Reference contracts" $ \(policy, address) ->
          ioProperty $ do
            contract <- generate $ elements referenceContracts
            let
              minAda = maybe 0 toInteger $ minAdaUpperBound protocolTestnet version contract continuations
              overspent (TransactionValidationError _ msg) = "The machine terminated part way through evaluation due to overspending the budget." `isInfixOf` msg
              overspent _ = False
            actual <- checkTransactions solveConstraints' version marloweContext policy address minAda contract continuations
            pure
              . counterexample ("Contract = " <> show contract)
              . counterexample ("Actual = " <> show actual)
              $ case actual of
                  -- Overspending is not a test failure.
                  Right errs -> all overspent errs
                  -- An ambiguous time interval occurs when the timeouts have non-zero milliseconds are too close for there to be a valid slot for a transaction.
                  Left "ApplyInputsConstraintsBuildupFailed (MarloweComputeTransactionFailed \"TEAmbiguousTimeIntervalError\")" -> True
                  -- All other results are test failures.
                  _ -> False
