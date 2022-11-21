{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Defines a custom Monad for the web server's handler functions to run in.

module Language.Marlowe.Runtime.Web.Server.Monad
  where

import Control.Monad.Base (MonadBase)
import Control.Monad.Catch (MonadCatch, MonadThrow)
import Control.Monad.Catch.Pure (MonadMask)
import Control.Monad.Cleanup (MonadCleanup(..))
import Control.Monad.Except (ExceptT, MonadError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks)
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Coerce (coerce)
import Language.Marlowe.Runtime.Web.Server.ContractHeaderIndexer (LoadContractHeaders)
import Language.Marlowe.Runtime.Web.Server.HistoryClient (LoadContract, LoadTransactions)
import Language.Marlowe.Runtime.Web.Server.TxClient (CreateContract)
import Servant

newtype AppM r a = AppM { runAppM :: ReaderT (AppEnv r) Handler a }
  deriving newtype
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    , MonadReader (AppEnv r)
    , MonadFail
    , MonadCatch
    , MonadMask
    , MonadThrow
    , MonadBaseControl IO
    , MonadError ServerError
    , MonadBase IO
    )

instance MonadCleanup (AppM r) where
  generalCleanup acquire release action = coerce $ generalCleanup
    (toTransformers acquire)
    (\a b -> toTransformers $ release a b)
    (\a -> toTransformers $ action a)
    where
      toTransformers :: AppM r a -> ReaderT (AppEnv r) (ExceptT ServerError IO) a
      toTransformers = coerce

data AppEnv r = AppEnv
  { _loadContractHeaders :: LoadContractHeaders IO
  , _loadContract :: LoadContract r IO
  , _loadTransactions :: LoadTransactions r IO
  , _createContract :: CreateContract IO
  }

-- | Load a list of contract headers.
loadContractHeaders :: LoadContractHeaders (AppM r)
loadContractHeaders startFrom limit offset order = do
  load <- asks _loadContractHeaders
  liftIO $ load startFrom limit offset order

-- | Load a list of contract headers.
loadContract :: LoadContract r (AppM r)
loadContract mods contractId = do
  load <- asks _loadContract
  liftIO $ load mods contractId

-- | Load a list of transactions for a contract.
loadTransactions :: LoadTransactions r (AppM r)
loadTransactions mods contractId startFrom limit offset order = do
  load <- asks _loadTransactions
  liftIO $ load mods contractId startFrom limit offset order

-- | Load a list of transactions for a contract.
createContract :: CreateContract (AppM r)
createContract stakeCredential version addresses roles metadata minUTxODeposit contract = do
  create <- asks _createContract
  liftIO $ create stakeCredential version addresses roles metadata minUTxODeposit contract
