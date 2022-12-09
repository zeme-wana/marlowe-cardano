{-# LANGUAGE GADTs #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Main
  where

import Colog (LoggerT)
import qualified Colog
import Control.Arrow (arr, (<<<))
import Control.Concurrent.Component
import Control.Exception (bracket, bracketOnError, throwIO)
import Control.Monad.Cleanup (MonadCleanup)
import Control.Monad.IO.Class (liftIO)
import Data.Either (fromRight)
import qualified Data.Text.Lazy.IO as TL
import Data.UUID.V4 (nextRandom)
import Data.Void (Void)
import Language.Marlowe.Protocol.Sync.Client (MarloweSyncClient, marloweSyncClientPeer)
import Language.Marlowe.Protocol.Sync.Codec (codecMarloweSync)
import Language.Marlowe.Runtime.CLI.Option (Verbosity(LogLevel, Silent), verbosityParser)
import Language.Marlowe.Runtime.ChainSync.Api
  ( ChainSyncCommand
  , ChainSyncQuery(..)
  , GetUTxOsQuery
  , RuntimeChainSeekClient
  , UTxOs
  , WithGenesis(..)
  , chainSeekClientPeer
  , runtimeChainSeekCodec
  )
import Language.Marlowe.Runtime.Logging (mkLogger)
import Language.Marlowe.Runtime.Transaction (TransactionDependencies(..), transaction)
import Language.Marlowe.Runtime.Transaction.Query (LoadMarloweContext, LoadWalletContext)
import qualified Language.Marlowe.Runtime.Transaction.Query as Query
import qualified Language.Marlowe.Runtime.Transaction.Submit as Submit
import Logging (RootSelector(..), getRootSelectorConfig)
import Network.Protocol.Driver (acceptRunServerPeerOverSocketWithLogging, runClientPeerOverSocketWithLogging)
import Network.Protocol.Job.Client (JobClient, jobClientPeer)
import Network.Protocol.Job.Codec (codecJob)
import Network.Protocol.Job.Server (jobServerPeer)
import Network.Protocol.Query.Client (liftQuery, queryClientPeer)
import Network.Protocol.Query.Codec (codecQuery)
import Network.Socket
  ( AddrInfo(..)
  , AddrInfoFlag(..)
  , HostName
  , PortNumber
  , SocketOption(..)
  , SocketType(..)
  , bind
  , close
  , defaultHints
  , getAddrInfo
  , listen
  , openSocket
  , setCloseOnExecIfNeeded
  , setSocketOption
  , withFdSocket
  , withSocketsDo
  )
import Observe.Event.Backend (hoistEventBackend, narrowEventBackend, newOnceFlagMVar)
import Observe.Event.Component (LoggerDependencies(..), logger)
import Options.Applicative
  ( auto
  , execParser
  , fullDesc
  , header
  , help
  , helper
  , info
  , long
  , metavar
  , option
  , optional
  , progDesc
  , short
  , showDefault
  , strOption
  , value
  )
import System.IO (stderr)

main :: IO ()
main = run =<< getOptions

clientHints :: AddrInfo
clientHints = defaultHints { addrSocketType = Stream }

deriving newtype instance MonadCleanup m => MonadCleanup (LoggerT msg m)

run :: Options -> IO ()
run Options{..} = withSocketsDo do
  addr <- resolve port

  let
    mainLogAction :: Colog.LogAction IO Colog.Message
    mainLogAction = mkLogger $ case verbosity of
      Silent -> Nothing
      LogLevel severity -> Just severity

  bracket (openServer addr) close \socket -> do
    Colog.withBackgroundLogger Colog.defCapacity mainLogAction \logAction -> do
      {- Setup Dependencies -}
      let
        transactionDependencies eventBackend =
          let
            acceptRunTransactionServer = acceptRunServerPeerOverSocketWithLogging
              (narrowEventBackend Server $ hoistEventBackend liftIO eventBackend)
              (liftIO . throwIO)
              socket
              codecJob
              jobServerPeer

            runHistorySyncClient :: MarloweSyncClient IO a -> IO a
            runHistorySyncClient client = do
              addr' <- head <$> getAddrInfo (Just clientHints) (Just historyHost) (Just $ show historySyncPort)
              runClientPeerOverSocketWithLogging
                (narrowEventBackend HistoryClient eventBackend)
                throwIO
                addr'
                codecMarloweSync
                marloweSyncClientPeer
                client

            connectToChainSeek :: RuntimeChainSeekClient IO a -> IO a
            connectToChainSeek client = do
              addr' <- head <$> getAddrInfo (Just clientHints) (Just chainSeekHost) (Just $ show chainSeekPort)
              runClientPeerOverSocketWithLogging
                (narrowEventBackend ChainSeekClient eventBackend)
                throwIO
                addr'
                runtimeChainSeekCodec
                (chainSeekClientPeer Genesis)
                client

            runChainSyncJobClient :: JobClient ChainSyncCommand IO a -> IO a
            runChainSyncJobClient client = do
              addr' <- head <$> getAddrInfo (Just clientHints) (Just chainSeekHost) (Just $ show chainSeekCommandPort)
              runClientPeerOverSocketWithLogging
                (narrowEventBackend ChainSyncJobClient eventBackend)
                throwIO
                addr'
                codecJob
                jobClientPeer
                client

            queryChainSync :: ChainSyncQuery Void e a -> IO a
            queryChainSync query = do
              addr' <- head <$> getAddrInfo (Just clientHints) (Just chainSeekHost) (Just $ show chainSeekQueryPort)
              result <- runClientPeerOverSocketWithLogging
                (narrowEventBackend ChainSyncQueryClient eventBackend)
                throwIO
                addr'
                codecQuery
                queryClientPeer
                (liftQuery query)
              pure $ fromRight (error "failed to query chain seek server") result

            mkSubmitJob = Submit.mkSubmitJob Submit.SubmitJobDependencies{..}

            loadMarloweContext :: LoadMarloweContext
            loadMarloweContext version contractId = do
              networkId <- queryChainSync GetNetworkId
              Query.loadMarloweContext networkId runHistorySyncClient version contractId

            runGetUTxOsQuery :: GetUTxOsQuery -> IO UTxOs
            runGetUTxOsQuery getUTxOsQuery = queryChainSync (GetUTxOs getUTxOsQuery)

            loadWalletContext :: LoadWalletContext
            loadWalletContext = Query.loadWalletContext runGetUTxOsQuery
          in TransactionDependencies{..}
        appComponent = transaction <<< arr transactionDependencies <<< logger
      runComponent_ appComponent LoggerDependencies
        { configFilePath = logConfigFile
        , getSelectorConfig = getRootSelectorConfig
        , newRef = nextRandom
        , newOnceFlag = newOnceFlagMVar
        , writeText = TL.hPutStr stderr
        , injectConfigWatcherSelector = ConfigWatcher
        }
  where
    openServer addr = bracketOnError (openSocket addr) close \socket -> do
      setSocketOption socket ReuseAddr 1
      withFdSocket socket setCloseOnExecIfNeeded
      bind socket $ addrAddress addr
      listen socket 2048
      return socket

    resolve p = do
      let hints = defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }
      head <$> getAddrInfo (Just hints) (Just host) (Just $ show p)

data Options = Options
  { chainSeekPort      :: PortNumber
  , chainSeekQueryPort :: PortNumber
  , chainSeekCommandPort :: PortNumber
  , chainSeekHost      :: HostName
  , port               :: PortNumber
  , host               :: HostName
  , historySyncPort :: PortNumber
  , historyHost :: HostName
  , verbosity  :: Verbosity
  , logConfigFile  :: Maybe FilePath
  }

getOptions :: IO Options
getOptions = execParser $ info (helper <*> parser) infoMod
  where
    parser = Options
      <$> chainSeekPortParser
      <*> chainSeekQueryPortParser
      <*> chainSeekCommandPortParser
      <*> chainSeekHostParser
      <*> portParser
      <*> hostParser
      <*> historySyncPortParser
      <*> historyHostParser
      <*> verbosityParser (LogLevel Colog.Error)
      <*> logConfigFileParser

    chainSeekPortParser = option auto $ mconcat
      [ long "chain-seek-port-number"
      , value 3715
      , metavar "PORT_NUMBER"
      , help "The port number of the chain seek server."
      , showDefault
      ]

    chainSeekQueryPortParser = option auto $ mconcat
      [ long "chain-seek-query-port-number"
      , value 3716
      , metavar "PORT_NUMBER"
      , help "The port number of the chain sync query server."
      , showDefault
      ]

    chainSeekCommandPortParser = option auto $ mconcat
      [ long "chain-seek-command-port-number"
      , value 3720
      , metavar "PORT_NUMBER"
      , help "The port number of the chain sync job server."
      , showDefault
      ]

    portParser = option auto $ mconcat
      [ long "command-port"
      , value 3723
      , metavar "PORT_NUMBER"
      , help "The port number to run the job server on."
      , showDefault
      ]

    chainSeekHostParser = strOption $ mconcat
      [ long "chain-seek-host"
      , value "127.0.0.1"
      , metavar "HOST_NAME"
      , help "The host name of the chain seek server."
      , showDefault
      ]

    hostParser = strOption $ mconcat
      [ long "host"
      , short 'h'
      , value "127.0.0.1"
      , metavar "HOST_NAME"
      , help "The host name to run the tx server on."
      , showDefault
      ]

    historySyncPortParser = option auto $ mconcat
      [ long "history-sync-port"
      , value 3719
      , metavar "PORT_NUMBER"
      , help "The port number of the history sync server."
      , showDefault
      ]

    historyHostParser = strOption $ mconcat
      [ long "history-host"
      , value "127.0.0.1"
      , metavar "HOST_NAME"
      , help "The host name of the history server."
      , showDefault
      ]

    logConfigFileParser = optional $ strOption $ mconcat
      [ long "log-config-file"
      , metavar "FILE_PATH"
      , help "The logging configuration JSON file."
      ]

    infoMod = mconcat
      [ fullDesc
      , progDesc "Marlowe runtime transaction creation server"
      , header "marlowe-tx : the transaction creation server of the Marlowe Runtime"
      ]
