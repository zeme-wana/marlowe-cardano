{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeSynonymInstances  #-}

module Spec.Marlowe.ACTUS.TestFrameworkMarlowe
  ( tests,
  )
where

import Control.Monad.Reader (Reader, ask, runReader)
import Data.Char (toUpper)
import Data.List as L (find)
import Data.Map as Map (lookup)
import Data.Maybe (fromMaybe)
import GHC.Records (getField)
import Language.Marlowe
import Language.Marlowe.ACTUS.Domain.BusinessEvents
import Language.Marlowe.ACTUS.Domain.ContractTerms hiding (Assertion)
import Language.Marlowe.ACTUS.Domain.Ops
import Language.Marlowe.ACTUS.Domain.Schedule
import Language.Marlowe.ACTUS.Generator.Analysis
import Language.Marlowe.ACTUS.Generator.MarloweCompat (constnt, toMarlowe)
import Language.Marlowe.ACTUS.Model.ContractSchedule as S (maturity, schedule)
import Language.Marlowe.ACTUS.Model.StateTransition (CtxSTF (..))
import Language.Marlowe.ACTUS.Utility.DateShift (applyBDCWithCfg)
import Spec.Marlowe.ACTUS.TestFramework hiding (run, tests)
import Test.Tasty
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase)

tests :: String -> [TestCase] -> TestTree
tests n t =
  testGroup
    n
    [testCase (getField @"identifier" tc) (runTest tc {terms = setDefaultContractTermValues (terms tc)}) | tc <- t]
  where
    runTest :: TestCase -> Assertion
    runTest tc@TestCase {..} =
      let riskFactors ev date =
            let rf =
                  RiskFactorsPoly
                    { o_rf_CURS = _one,
                      o_rf_RRMO = _one,
                      o_rf_SCMO = _one,
                      pp_payoff = _zero,
                      xd_payoff = _zero,
                      dv_payoff = _zero
                    }

                observedKey RR = marketObjectCodeOfRateReset terms
                observedKey SC = marketObjectCodeOfScalingIndex terms
                observedKey DV = Just (fmap toUpper identifier ++ "_DV")
                observedKey XD = Prelude.head $ map (getMarketObjectCode . reference) (contractStructure terms)
                observedKey _  = settlementCurrency terms

                v = fromMaybe _one $ do
                  k <- observedKey ev
                  DataObserved {values} <- Map.lookup k dataObserved
                  ValueObserved {value} <-
                    L.find
                      ( \ValueObserved {timestamp} ->
                          let d = applyBDCWithCfg (scheduleConfig terms) timestamp in calculationDay d == date
                      )
                      values
                  return $ constnt value
             in case ev of
                  RR -> rf {o_rf_RRMO = v}
                  SC -> rf {o_rf_SCMO = v}
                  DV -> rf {dv_payoff = v}
                  XD -> rf {xd_payoff = v}
                  _  -> rf {o_rf_CURS = v}

          cashFlows =
            runReader
              (run tc)
              $ CtxSTF
                (toMarlowe terms)
                (calculationDay <$> schedule FP terms)
                (calculationDay <$> schedule PR terms)
                (calculationDay <$> schedule IP terms)
                (S.maturity terms)
                riskFactors
       in assertTestResults cashFlows results

    assertTestResults :: [CashFlowPoly (Value Observation)] -> [TestResult] -> IO ()
    assertTestResults [] []               = return ()
    assertTestResults (cf : cfs) (r : rs) = assertTestResult cf r >> assertTestResults cfs rs
    assertTestResults _ _                 = assertFailure "Sizes differ"

assertTestResult :: CashFlowPoly (Value Observation) -> TestResult -> IO ()
assertTestResult CashFlowPoly {..} TestResult {eventDate, eventType, payoff} = do
  assertBool "Mismatch" $ cashEvent == eventType
  assertBool "Mismatch" $ cashPaymentDay == eventDate
  assertBool "Mismatch" obs
  where
    env = Environment {timeInterval = (POSIXTime 0, POSIXTime 0)}
    state = emptyState $ POSIXTime 0
    obs =
      evalObservation
        env
        state
        (ValueLE val (Constant marloweFixedPoint))
    val = _abs $ SubValue amount (constnt payoff)

run :: TestCase -> Reader (CtxSTF (Value Observation)) [CashFlowPoly (Value Observation)]
run TestCase {..} = do
  ctx <- ask
  pof <- genProjectedPayoffs
  let schedCfs = genCashflow (contractTerms ctx) <$> pof
  return $ maybe schedCfs (\d -> filter ((<= d) . cashCalculationDay) schedCfs) to
