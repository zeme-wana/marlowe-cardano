
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}


module Spec.Marlowe.Semantics.Arbitrary (
  SemiArbitrary(..)
, IsValid(..)
, arbitraryChoiceName
, arbitraryFibonacci
, defaultContractWeights
, closeContractWeights
, payContractWeights
, ifContractWeights
, whenContractWeights
, letContractWeights
, assertContractWeights
, arbitraryContractWeighted
) where


import Control.Monad (replicateM)
import Data.Function (on)
import Data.List (nubBy)
import Language.Marlowe.Core.V1.Semantics.Types (Accounts, Action (..), Bound (..), Case (..), ChoiceId (..),
                                                 ChoiceName, ChosenNum, Contract (..), Environment (..), Input (..),
                                                 InputContent (..), Observation (..), Party (..), Payee (..),
                                                 State (..), TimeInterval, Token (..), Value (..), ValueId (..))
import Plutus.V1.Ledger.Api (CurrencySymbol (..), POSIXTime (..), PubKeyHash (..), TokenName (..), adaSymbol, adaToken)
import PlutusTx.Builtins (BuiltinByteString, lengthOfByteString)
import Test.Tasty.QuickCheck (Arbitrary (..), Gen, elements, frequency, listOf, suchThat)

import qualified PlutusTx.AssocMap as AM (Map, delete, fromList, keys, toList)
import qualified PlutusTx.Eq as P (Eq)


fibonaccis :: Num a => [a]
fibonaccis = [2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584]


fibonacciFrequencies :: Integral a => [a]
fibonacciFrequencies = (1000000 `div`) <$> fibonaccis


arbitraryFibonacci :: [a] -> Gen a
arbitraryFibonacci = frequency . zip fibonacciFrequencies . fmap pure


shrinkByteString :: (a -> BuiltinByteString) -> [a] -> a -> [a]
shrinkByteString f universe selected =
  filter
    (\candidate -> lengthOfByteString (f candidate) > 0 && lengthOfByteString (f candidate) < lengthOfByteString (f selected))
    universe


perturb :: Gen a -> [a] -> Gen a
perturb gen [] = gen
perturb gen xs = frequency [(20, gen), (80, elements xs)]


data Context =
  Context
  {
    parties      :: [Party]
  , tokens       :: [Token]
  , amounts      :: [Integer]
  , choiceNames  :: [ChoiceName]
  , chosenNums   :: [ChosenNum]
  , choiceIds    :: [ChoiceId]
  , valueIds     :: [ValueId]
  , values       :: [Integer]
  , times        :: [POSIXTime]
  , caccounts    :: Accounts
  , cchoices     :: AM.Map ChoiceId ChosenNum
  , cboundValues :: AM.Map ValueId Integer
  }

instance Arbitrary Context where
  arbitrary =
    do
      parties <- arbitrary
      tokens <- arbitrary
      amounts <- listOf arbitraryPositiveInteger
      choiceNames <- listOf arbitraryChoiceName
      chosenNums <- listOf arbitraryInteger
      valueIds <- arbitrary
      values <- listOf arbitraryInteger
      times <- listOf arbitrary
      choiceIds <- listOf $ ChoiceId <$> perturb arbitraryChoiceName choiceNames <*> perturb arbitrary parties
      caccounts <- AM.fromList . nubBy ((==) `on` fst) <$> listOf ((,) <$> ((,) <$> perturb arbitrary parties <*> perturb arbitrary tokens) <*> perturb arbitraryPositiveInteger amounts)
      cchoices <- AM.fromList . nubBy ((==) `on` fst) <$> listOf ((,) <$> perturb arbitrary choiceIds <*> perturb arbitraryInteger chosenNums)
      cboundValues <- AM.fromList . nubBy ((==) `on` fst) <$> listOf ((,) <$> perturb arbitrary valueIds <*> perturb arbitraryInteger values)
      pure Context{..}
  shrink context@Context{..} =
    [context {parties = parties'} | parties' <- shrink parties]
      ++ [context {tokens = tokens'} | tokens' <- shrink tokens]
      ++ [context {amounts = amounts'} | amounts' <- shrink amounts]
--    ++ [context {choiceNames = choiceNames'} | choiceNames' <- shrink choiceNames]  -- TODO: Implement `shrink`.
      ++ [context {chosenNums = chosenNums'} | chosenNums' <- shrink chosenNums]
      ++ [context {valueIds = valueIds'} | valueIds' <- shrink valueIds]
      ++ [context {values = values'} | values' <- shrink values]
      ++ [context {times = times'} | times' <- shrink times]
      ++ [context {choiceIds = choiceIds'} | choiceIds' <- shrink choiceIds]
      ++ [context {caccounts = caccounts'} | caccounts' <- shrink caccounts]
      ++ [context {cchoices = cchoices'} | cchoices' <- shrink cchoices]
      ++ [context {cboundValues = cboundValues'} | cboundValues' <- shrink cboundValues]



class Arbitrary a => SemiArbitrary a where
  semiArbitrary :: Context -> Gen a
  semiArbitrary context =
     case fromContext context of
       [] -> arbitrary
       xs -> perturb arbitrary xs
  shrink' :: [a] -> [[a]]
  shrink' = shrink
  fromContext :: Context -> [a]
  fromContext _ = []


class IsValid a where
  isValid :: a -> Bool

instance IsValid Accounts where
  isValid am =
    let
      am' = AM.toList am
      am'' = nubBy ((==) `on` fst) $ filter ((> 0) . snd) am'
    in
      ((==) `on` length) am' am''

instance IsValid (AM.Map ChoiceId ChosenNum) where
  isValid am =
    let
      am' = AM.toList am
      am'' = nubBy ((==) `on` fst) am'
    in
      ((==) `on` length) am' am''

instance IsValid (AM.Map ValueId Integer) where
  isValid am =
    let
      am' = AM.toList am
      am'' = nubBy ((==) `on` fst) am'
    in
      ((==) `on` length) am' am''

instance IsValid Context where
  isValid Context{..} = isValid caccounts && isValid cchoices && isValid cboundValues


arbitraryPositiveInteger :: Gen Integer
arbitraryPositiveInteger =
  frequency
    [
      (60, arbitrary `suchThat` (> 0))
    , (30, arbitraryFibonacci fibonaccis)
    ]


arbitraryInteger :: Gen Integer
arbitraryInteger =
  frequency
    [
      ( 5, arbitrary `suchThat` (< 0))
    , (60, arbitrary `suchThat` (> 0))
    , ( 5, pure 0)
    , (30, arbitraryFibonacci fibonaccis)
    ]


randomPubKeyHashes :: [PubKeyHash]
randomPubKeyHashes =
  [
    "03e718291f87b2b004caac168d55e81da688e4501ce560ae613fa7e7"
  , "1b4a1ddd07976d3eee561fdce46d70f2f4c03985195906c08f547249"
  , "2f7bbc9ac7345b557515f6313cd66730241f2b0300c46b12f083ef46"
  , "40db357de24517df3f94cda9b7cc8078a0031d1e4a42cea9127cc730"
  , "592790c9e6af421fff4ffd7ad91de5aed0a703a03445beb8efb17fbf"
  , "6487e89309a827dc94d0e4a9b509c218fb405749d7d4f3fce3ea03f7"
  , "657e1b6b758226ad1c43d544f1d628daadf4eb4b6b411fbbc547ba7c"
  , "7b6fcf5a5528d3ee37493391fd4536a46f9aa63d41bdae6506ecf58d"
  , "8169906694a3558bd393fdd404a60b0ddb51a5e6c018698054f92f0a"
  , "85f24903d9a4f7a9b7284c0440882b1b9e0946ec51ee8cce40ad423b"
  , "9845463ec1285b4f6923133bf58517e4d90d1b1a71263f882ea6911d"
  , "a2bd7dd7f41c2781d1d11c7f4994fac750525705f9c259f97cb27d0e"
  , "c5b4c543a0d0d181ec387ad8250b18617bb18bcf2eccc0f27fe7aa23"
  , "d877b83ece77d785fee4a52bd7226949fa64e111aa0e20cd4a1c471b"
  , "e14025a93f867851b9bb3c48601d1845bcbe9e2e1856c16cfc0522"      -- NB: Too short for ledger.
  , "e3351d289f3eaa66e500f17b91a74e492193f4485c32e5ad606da83542"  -- NB: Too long for ledger.
  ]


instance Arbitrary PubKeyHash where
  arbitrary = arbitraryFibonacci randomPubKeyHashes
  shrink x = filter (< x) randomPubKeyHashes


randomCurrencySymbols :: [CurrencySymbol]
randomCurrencySymbols =
  [
    "13e78e78c233e131b0cbe4424225d338b7c5ac65e16df0a3e6c9d8f8"
  , "1b9af43b0eaafc42dfaefbbf4e71437af45454c7292a6b6606363741"
  , "23d79373f7d9edbd016c99e21a473f498a2e425491244ecbc663e9d0"
  , "2839d40108e194eced45205c89613df56bd482e07e6c81a1df2b0e9b"
  , "2c60fb96c894b099f1a21ca9cf51c8c46a4672eb9a30b85252e9adb7"
  , "35c100db45fdf04b9317a2c520c2638ead47fd792984f32c9652cbc7"
  , "443d7002ac74be8c3c53f901d95c89c5932ee8946b188ca9f59db24e"
  , "63f3875b161780b82c7706fbc36fe906e54742e9f5b4c68d260e5da9"
  , "64da8cbb98eccc616bb0061efed2717393e4b48d8f78147396f4521f"
  , "66879477b60f46e5c5ad1d1bb124ab5c3d46a3acc9e54b7da4259655"
  , "9019bb7fb44ec03537b61a6f4aa3fd7b1effaf0776c3d449e9c6274e"
  , "9f92753881b398a247e53b6cad08eab0e158cf1ef5df84c7f5766041"
  , "c1f46ec0147542f9bc155805993497ed44150687a41d0a63af3be466"
  , "cc2189d7adde0ed26355fd03e134feb508e5924959b07a53557f285e"
  , "df97bf95b2d21327731329d94173344ff4db5ac16f92250d9cab00"      -- NB: Too short for ledger.
  , "ead659651c55f5481dbc7038a7c096fd7616d2f86471bd9d46de742ea0"  -- NB: Too long for ledger.
 ]

instance Arbitrary CurrencySymbol where
  arbitrary = arbitraryFibonacci randomCurrencySymbols
  shrink x = filter (< x) randomCurrencySymbols


randomTokenNames :: [TokenName]
randomTokenNames =
  [
    "I"
  , "AD"
  , "PIN"
  , "TALE"
  , "RIVER"
  , "METHOD"
  , "REVENUE"
  , ""
  , "POSSIBILITY"
  , "SATISFACTION"
  , "PAYMENT CONCEPT"
  , "OFFICE DEFINITION"
  , "ARTISAN CONVERSATION"
  , "SOFTWARE FEEDBACK METHOD"
  , "INDEPENDENCE EXPLANATION REVENUE"
  , "RELATIONSHIPS FEEDBACK CONCEPT METHOD"  -- NB: Too long for ledger.
  ]

instance Arbitrary TokenName where
  arbitrary = arbitraryFibonacci randomTokenNames
  shrink = shrinkByteString (\(TokenName x) -> x) randomTokenNames


instance Arbitrary Token where
  arbitrary =
     do
       isAda <- arbitrary
       if isAda
         then pure $ Token adaSymbol adaToken
         else Token <$> arbitrary <*> arbitrary
  shrink (Token c n)
    | c == adaSymbol && n == adaToken = []
    | otherwise                       = Token adaSymbol adaToken : [Token c' n' | c' <- shrink c, n' <- shrink n]


instance SemiArbitrary Token where
  fromContext = tokens


randomRoleNames :: [TokenName]
randomRoleNames =
  [
    "Cy"
  , "Noe"
  , "Sten"
  , "Cara"
  , "Alene"
  , "Hande"
  , ""
  , "I"
  , "Zakkai"
  , "Laurent"
  , "Prosenjit"
  , "Dafne Helge Mose"
  , "Nonso Ernie Blanka"
  , "Umukoro Alexander Columb"
  , "Urbanus Roland Alison Ty Ryoichi"
  , "Alcippe Alende Blanka Roland Dafne"  -- NB: Too long for ledger.
  ]

instance Arbitrary Party where
  arbitrary =
    do
       isPubKeyHash <- frequency [(2, pure True), (8, pure False)]
       if isPubKeyHash
         then PK <$> arbitrary
         else Role <$> arbitraryFibonacci randomRoleNames
  shrink (PK x)   = (Role <$> randomRoleNames) <> (PK <$> filter (< x) randomPubKeyHashes)
  shrink (Role x) = Role <$> shrinkByteString (\(TokenName y) -> y) randomRoleNames x

instance SemiArbitrary Party where
  fromContext = parties


instance Arbitrary POSIXTime where
  arbitrary = POSIXTime <$> arbitraryInteger
  shrink x = filter (< x) fibonaccis

instance SemiArbitrary POSIXTime where
  fromContext = times


randomChoiceNames :: [ChoiceName]
randomChoiceNames =
  [
    "be"
  , "dry"
  , "grab"
  , "weigh"
  , "enable"
  , "enhance"
  , "allocate"
  , ""
  , "originate"
  , "characterize"
  , "derive witness"
  , "envisage software"
  , "attend unknown animals"
  , "position increated radiation"
  , "proclaim endless sordid figments"
  , "understand weigh originate envisage"  -- NB: Too long for ledger.
  ]

arbitraryChoiceName :: Gen ChoiceName
arbitraryChoiceName = arbitraryFibonacci randomChoiceNames

shrinkChoiceName :: ChoiceName -> [ChoiceName]
shrinkChoiceName = shrinkByteString id randomChoiceNames


arbitraryTimeInterval :: Gen TimeInterval
arbitraryTimeInterval =
  do
    start <- arbitraryInteger
    duration <- arbitraryPositiveInteger
    pure (POSIXTime start, POSIXTime $ start + duration)

shrinkTimeInterval :: TimeInterval -> [TimeInterval]
shrinkTimeInterval (start, end) =
  let
    mid = (start + end) `div` 2
  in
    [
      (start, start)
    , (start, mid  )
    , (mid  , mid  )
    , (mid  , end  )
    , (end  , end  )
    ]

instance SemiArbitrary TimeInterval where
  semiArbitrary context =
    do
      POSIXTime start <- semiArbitrary context
      duration <- arbitraryPositiveInteger
      pure (POSIXTime start, POSIXTime $ start + duration)
  shrink' = fmap shrinkTimeInterval


instance Arbitrary ChoiceId where
  arbitrary = ChoiceId <$> arbitraryChoiceName <*> arbitrary
  shrink (ChoiceId n p) = [ChoiceId n' p' | n' <- shrinkChoiceName n, p' <- shrink p]

instance SemiArbitrary ChoiceId where
  fromContext = choiceIds


randomValueIds :: [ValueId]
randomValueIds =
  [
    "x"
  , "id"
  , "lab"
  , "idea"
  , "story"
  , "memory"
  , "fishing"
  , ""
  , "drawing"
  , "reaction"
  , "difference"
  , "replacement"
  , "paper apartment"
  , "leadership information"
  , "entertainment region assumptions"
  , "candidate apartment reaction replacement"  -- NB: Too long for ledger.
  ]

instance Arbitrary ValueId where
  arbitrary = arbitraryFibonacci randomValueIds
  shrink = shrinkByteString (\(ValueId x) -> x) randomValueIds

instance SemiArbitrary ValueId where
  fromContext = valueIds


arbitraryNumber :: (Context -> [Integer]) -> Context -> Gen Integer
arbitraryNumber = (perturb arbitraryInteger .)

arbitraryAmount :: Context -> Gen Integer
arbitraryAmount = arbitraryNumber amounts

arbitraryChosenNum :: Context -> Gen Integer
arbitraryChosenNum = arbitraryNumber chosenNums

arbitraryValueNum :: Context -> Gen Integer
arbitraryValueNum = arbitraryNumber values


instance SemiArbitrary Integer where
  semiArbitrary context =
    frequency
      [
        (1, arbitraryAmount    context)
      , (1, arbitraryChosenNum context)
      , (1, arbitraryValueNum  context)
      ]


instance Arbitrary (Value Observation) where
  arbitrary =
    frequency
      [
        ( 8, AvailableMoney <$> arbitrary <*> arbitrary)
      , (14, Constant <$> arbitrary)
      , ( 8, NegValue <$> arbitrary)
      , ( 8, AddValue <$> arbitrary <*> arbitrary)
      , ( 8, SubValue <$> arbitrary <*> arbitrary)
      , ( 8, MulValue <$> arbitrary <*> arbitrary)
      , ( 8, DivValue <$> arbitrary <*> arbitrary)
      , (10, ChoiceValue <$> arbitrary)
      , ( 6, pure TimeIntervalStart)
      , ( 6, pure TimeIntervalEnd)
      , ( 8, UseValue <$> arbitrary)
      , ( 8, Cond <$> arbitrary <*> arbitrary <*> arbitrary)
      ]
  shrink (AvailableMoney a t) = [AvailableMoney a' t | a' <- shrink a] ++ [AvailableMoney a t' | t' <- shrink t]
  shrink (Constant x) = Constant <$> shrink x
  shrink (NegValue x) = NegValue <$> shrink x
  shrink (AddValue x y) = [AddValue x' y | x' <- shrink x] ++ [AddValue x y' | y' <- shrink y]
  shrink (SubValue x y) = [SubValue x' y | x' <- shrink x] ++ [SubValue x y' | y' <- shrink y]
  shrink (MulValue x y) = [MulValue x' y | x' <- shrink x] ++ [MulValue x y' | y' <- shrink y]
  shrink (DivValue x y) = [DivValue x' y | x' <- shrink x] ++ [DivValue x y' | y' <- shrink y]
  shrink (ChoiceValue c) = ChoiceValue <$> shrink c
  shrink (UseValue v) = UseValue <$> shrink v
  shrink (Cond o x y) = [Cond o' x y | o' <- shrink o] ++ [Cond o x' y | x' <- shrink x] ++ [Cond o x y' | y' <- shrink y]
  shrink x = [x]

instance SemiArbitrary (Value Observation) where
  semiArbitrary context =
    frequency
      [
        ( 8, uncurry AvailableMoney <$> perturb ((,) <$> arbitrary <*> arbitrary) (AM.keys $ caccounts context))
      , (14, Constant <$> semiArbitrary context)
      , ( 8, NegValue <$> semiArbitrary context)
      , ( 8, AddValue <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, SubValue <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, MulValue <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, DivValue <$> semiArbitrary context <*> semiArbitrary context)
      , (10, ChoiceValue <$> semiArbitrary context)
      , ( 6, pure TimeIntervalStart)
      , ( 6, pure TimeIntervalEnd)
      , ( 8, UseValue <$> semiArbitrary context)
      , ( 8, Cond <$> semiArbitrary context <*> semiArbitrary context <*> semiArbitrary context)
      ]


instance Arbitrary Observation where
  arbitrary =
    frequency
      [
        ( 8, AndObs <$> arbitrary <*> arbitrary)
      , ( 8, OrObs <$> arbitrary <*> arbitrary)
      , ( 8, NotObs <$> arbitrary)
      , (16, ChoseSomething <$> arbitrary)
      , ( 8, ValueGE <$> arbitrary <*> arbitrary)
      , ( 8, ValueGT <$> arbitrary <*> arbitrary)
      , ( 8, ValueLT <$> arbitrary <*> arbitrary)
      , ( 8, ValueLE <$> arbitrary <*> arbitrary)
      , ( 8, ValueEQ <$> arbitrary <*> arbitrary)
      , (10, pure TrueObs)
      , (10, pure FalseObs)
      ]
  shrink (AndObs x y)       = [AndObs x' y | x' <- shrink x] ++ [AndObs x y' | y' <- shrink y]
  shrink (OrObs x y)        = [OrObs x' y | x' <- shrink x] ++ [OrObs x y' | y' <- shrink y]
  shrink (NotObs x)         = NotObs <$> shrink x
  shrink (ChoseSomething c) = ChoseSomething <$> shrink c
  shrink (ValueGE x y)      = [ValueGE x' y | x' <- shrink x] ++ [ValueGE x y' | y' <- shrink y]
  shrink (ValueGT x y)      = [ValueGT x' y | x' <- shrink x] ++ [ValueGT x y' | y' <- shrink y]
  shrink (ValueLT x y)      = [ValueLT x' y | x' <- shrink x] ++ [ValueLT x y' | y' <- shrink y]
  shrink (ValueLE x y)      = [ValueLE x' y | x' <- shrink x] ++ [ValueLE x y' | y' <- shrink y]
  shrink (ValueEQ x y)      = [ValueEQ x' y | x' <- shrink x] ++ [ValueEQ x y' | y' <- shrink y]
  shrink x                  = [x]

instance SemiArbitrary Observation where
  semiArbitrary context =
    frequency
      [
        ( 8, AndObs <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, OrObs <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, NotObs <$> semiArbitrary context)
      , (16, ChoseSomething <$> semiArbitrary context)
      , ( 8, ValueGE <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, ValueGT <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, ValueLT <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, ValueLE <$> semiArbitrary context <*> semiArbitrary context)
      , ( 8, ValueEQ <$> semiArbitrary context <*> semiArbitrary context)
      , (10, pure TrueObs)
      , (10, pure FalseObs)
      ]


instance Arbitrary Bound where
  arbitrary =
    do
      lower <- arbitraryInteger
      extent <- arbitraryPositiveInteger `suchThat` (>= 0)
      pure $ Bound lower (lower + extent)
  shrink (Bound lower upper) =
    let
      mid = (lower + upper) `div` 2
    in
      [
        Bound lower lower
      , Bound lower mid
      , Bound mid   mid
      , Bound mid   upper
      , Bound upper upper
      ]

instance SemiArbitrary Bound where
  semiArbitrary context =
      do
        lower <- semiArbitrary context
        extent <- arbitraryPositiveInteger `suchThat` (>= 0)
        pure $ Bound lower (lower + extent)


instance SemiArbitrary [Bound] where
  semiArbitrary context = listOf $ semiArbitrary context


instance Arbitrary Action where
  arbitrary =
    frequency
      [
        (3, Deposit <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary)
      , (6, Choice <$> arbitrary <*> arbitrary `suchThat` ((< 5) . length))
      , (1, Notify <$> arbitrary)
      ]
  shrink (Deposit a p t x) = [Deposit a' p t x | a' <- shrink a] ++ [Deposit a p' t x | p' <- shrink p] ++ [Deposit a p t' x | t' <- shrink t] ++ [Deposit a p t x' | x' <- shrink x]
  shrink (Choice c b) = [Choice c' b | c' <- shrink c] ++ [Choice c b' | b' <- shrink b]
  shrink (Notify o) = Notify <$> shrink o

instance SemiArbitrary Action where
  semiArbitrary context@Context{..} =
    let
      arbitraryDeposit =
        do
          (account, token) <- perturb ((,) <$> arbitrary <*> arbitrary) $ AM.keys caccounts
          party <- semiArbitrary context
          Deposit account party token <$> semiArbitrary context
      arbitraryChoice = Choice <$> semiArbitrary context <*> semiArbitrary context
    in
      frequency
        [
          (3, arbitraryDeposit)
        , (6, arbitraryChoice)
        , (1, Notify <$> semiArbitrary context)
        ]


instance Arbitrary Payee where
  arbitrary =
    do
      isParty <- arbitrary
      if isParty
        then Party <$> arbitrary
        else Account <$> arbitrary
  shrink (Party x)   = Party <$> shrink x
  shrink (Account x) = Account <$> shrink x


instance SemiArbitrary Payee where
  semiArbitrary context =
      do
        party <- semiArbitrary context
        isParty <- arbitrary
        pure
          $ if isParty
              then Party party
              else Account party


instance Arbitrary (Case Contract) where
  arbitrary = semiArbitrary =<< arbitrary
  shrink (Case a c)           = [Case a' c | a' <- shrink a] ++ [Case a c' | c' <- shrink c]
  shrink (MerkleizedCase a c) = (`MerkleizedCase` c) <$> shrink a

instance SemiArbitrary (Case Contract) where
  semiArbitrary context = Case <$> semiArbitrary context <*> semiArbitrary context

arbitraryCaseWeighted :: [(Int, Int, Int, Int, Int, Int)] -> Context -> Gen (Case Contract)
arbitraryCaseWeighted w context =
  Case <$> semiArbitrary context <*> arbitraryContractWeighted w context


instance Arbitrary Contract where
  arbitrary = semiArbitrary =<< arbitrary
  shrink (Pay a p t x c) = [Pay a' p t x c | a' <- shrink a] ++ [Pay a p' t x c | p' <- shrink p] ++ [Pay a p t' x c | t' <- shrink t] ++ [Pay a p t x' c | x' <- shrink x] ++ [Pay a p t x c' | c' <- shrink c]
  shrink (If o x y) = [If o' x y | o' <- shrink o] ++ [If o x' y | x' <- shrink x] ++ [If o x y' | y' <- shrink y]
  shrink (When a t c) = [When a' t c | a' <- shrink a] ++ [When a t' c | t' <- shrink t] ++ [When a t c' | c' <- shrink c]
  shrink (Let v x c) = [Let v' x c | v' <- shrink v] ++ [Let v x' c | x' <- shrink x] ++ [Let v x c' | c' <- shrink c]
  shrink (Assert o c) = [Assert o' c | o' <- shrink o] ++ [Assert o c' | c' <- shrink c]
  shrink x = [x]


arbitraryContractWeighted :: [(Int, Int, Int, Int, Int, Int)] -> Context -> Gen Contract
arbitraryContractWeighted ((wClose, wPay, wIf, wWhen, wLet, wAssert) : w) context =
  frequency
    [
      (wClose , pure Close)
    , (wPay   , Pay <$> semiArbitrary context <*> semiArbitrary context <*> semiArbitrary context <*> semiArbitrary context <*> arbitraryContractWeighted w context)
    , (wIf    , If <$> semiArbitrary context <*> arbitraryContractWeighted w context <*> arbitraryContractWeighted w context)
    , (wWhen  , When <$> listOf (arbitraryCaseWeighted w context) `suchThat` ((<= length w) . length) <*> semiArbitrary context <*> arbitraryContractWeighted w context)
    , (wLet   , Let <$> semiArbitrary context <*> semiArbitrary context <*> arbitraryContractWeighted w context)
    , (wAssert, Assert <$> semiArbitrary context <*> arbitraryContractWeighted w context)
    ]
arbitraryContractWeighted [] _ = pure Close

defaultContractWeights :: (Int, Int, Int, Int, Int, Int)
defaultContractWeights = (35, 20, 10, 15, 20, 5)

closeContractWeights :: (Int, Int, Int, Int, Int, Int)
closeContractWeights = (1, 0, 0, 0, 0, 0)

payContractWeights :: (Int, Int, Int, Int, Int, Int)
payContractWeights = (0, 1, 0, 0, 0, 0)

ifContractWeights :: (Int, Int, Int, Int, Int, Int)
ifContractWeights = (0, 0, 1, 0, 0, 0)

whenContractWeights :: (Int, Int, Int, Int, Int, Int)
whenContractWeights = (0, 0, 0, 1, 0, 0)

letContractWeights :: (Int, Int, Int, Int, Int, Int)
letContractWeights = (0, 0, 0, 0, 1, 0)

assertContractWeights :: (Int, Int, Int, Int, Int, Int)
assertContractWeights = (0, 0, 0, 0, 0, 1)

arbitraryContractSized :: Int -> Context -> Gen Contract
arbitraryContractSized = arbitraryContractWeighted . (`replicate` defaultContractWeights)

instance SemiArbitrary Contract where
  semiArbitrary = arbitraryContractSized 5


arbitraryAssocMap :: Eq k => Gen k -> Gen v -> Gen (AM.Map k v)
arbitraryAssocMap arbitraryKey arbitraryValue =
  do
    entries <- arbitraryFibonacci [0..]
    fmap (AM.fromList . nubBy ((==) `on` fst))
      . replicateM entries
      $ (,) <$> arbitraryKey <*> arbitraryValue


shrinkAssocMap :: P.Eq k => AM.Map k v -> [AM.Map k v]
shrinkAssocMap am =
  [
    AM.delete k am
  |
    k <- AM.keys am
  ]


instance Arbitrary Accounts where
  arbitrary = arbitraryAssocMap ((,) <$> arbitrary <*> arbitrary) arbitraryPositiveInteger
  shrink = shrinkAssocMap


instance SemiArbitrary Accounts where
  semiArbitrary context =
    do
      entries <- arbitraryFibonacci [0..]
      fmap (AM.fromList . nubBy ((==) `on` fst))
        . replicateM entries
        $ (,) <$> semiArbitrary context <*> (semiArbitrary context `suchThat` (> 0))

instance SemiArbitrary (Party, Token) where
  semiArbitrary context = (,) <$> semiArbitrary context <*> semiArbitrary context

instance Arbitrary (AM.Map ChoiceId ChosenNum) where
  arbitrary = arbitraryAssocMap arbitrary arbitraryInteger
  shrink = shrinkAssocMap


instance SemiArbitrary (AM.Map ChoiceId ChosenNum) where
  semiArbitrary context = arbitraryAssocMap (semiArbitrary context) (semiArbitrary context)


instance Arbitrary (AM.Map ValueId Integer) where
  arbitrary = arbitraryAssocMap arbitrary arbitraryInteger
  shrink = shrinkAssocMap


instance SemiArbitrary (AM.Map ValueId Integer) where
  semiArbitrary context = arbitraryAssocMap (semiArbitrary context) (semiArbitrary context)


instance Arbitrary State where
  arbitrary = semiArbitrary =<< arbitrary
  shrink s@State{..} =
    [s {accounts = accounts'} | accounts' <- shrinkAssocMap accounts]
      <> [s {choices = choices'} | choices' <- shrinkAssocMap choices]
      <> [s {boundValues = boundValues'} | boundValues' <- shrinkAssocMap boundValues]
      <> [s {minTime = minTime'} | minTime' <- shrink minTime]

instance SemiArbitrary State where
  semiArbitrary context =
    do
      accounts <- semiArbitrary context
      choices <- semiArbitrary context
      boundValues <- semiArbitrary context
      minTime <- semiArbitrary context
      pure State{..}


instance Arbitrary Environment where
  arbitrary = Environment <$> arbitraryTimeInterval
  shrink (Environment x) = Environment <$> shrink x

instance SemiArbitrary Environment where
  semiArbitrary context = Environment <$> semiArbitrary context


instance Arbitrary InputContent where
  arbitrary = semiArbitrary =<< arbitrary
  shrink (IDeposit a p t x) = [IDeposit a' p t x | a' <- shrink a] ++ [IDeposit a p' t x | p' <- shrink p] ++ [IDeposit a p t' x | t' <- shrink t] ++ [IDeposit a p t x' | x' <- shrink x]
  shrink (IChoice c x) = [IChoice c' x | c' <- shrink c] ++ [IChoice c x' | x' <- shrink x]
  shrink x = [x]

instance SemiArbitrary InputContent where
  semiArbitrary context =
    do
      deposit <- IDeposit <$> semiArbitrary context <*> semiArbitrary context <*> semiArbitrary context <*> arbitrary
      choice <- IChoice <$> semiArbitrary context <*> semiArbitrary context
      elements [deposit, choice, INotify]


instance Arbitrary Input where
  arbitrary = NormalInput <$> arbitrary
  shrink (NormalInput i)         = NormalInput <$> shrink i
  shrink (MerkleizedInput i b c) = [MerkleizedInput i' b c | i' <- shrink i]

instance SemiArbitrary Input where
  semiArbitrary context = NormalInput <$> semiArbitrary context
