{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
module Network.Haskoin.Stratum.Client
( StratumClient
, StratumClientState(..)
, getStratumClient
, queryStratumTCP
, runStratumTCP
, genReq
) where

import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Control.Monad.Trans (MonadIO, lift, liftIO)
import Control.Monad.Trans.Control (MonadBaseControl, control)
import Data.Conduit (Consumer, Producer, ($$), ($=), (=$), transPipe)
import qualified Data.Conduit.Binary as ConduitBinary
import qualified Data.Conduit.List as ConduitList
import Data.Conduit.Network
    ( ClientSettings
    , appSource
    , appSink
    , runTCPClient
    )
import Network.Haskoin.Stratum.JSONRPC.Conduit
import Network.Haskoin.Stratum.Types

-- | Stratum client context.
type StratumClient m = ReaderT (StratumClientState m, StratumSession) m

-- | Conduits for the Stratum application.
data StratumClientState m = StratumClientStateTCP
    { stratumSrc  :: Producer m MsgStratum
    , stratumSink :: Consumer RequestStratum m ()
    }

-- | Get Stratum client state.
getStratumClient :: MonadIO m => StratumClient m (StratumClientState m)
getStratumClient = ask >>= return . fst

-- | Generate a Stratum request.
genReq :: MonadIO m => StratumQuery -> StratumClient m RequestStratum
genReq q = ask >>= \(_, s) -> lift $ newStratumReq s q

-- | Connect via TCP to Stratum server and run batch of queries.
queryStratumTCP :: (MonadIO m, MonadBaseControl IO m)
             => ClientSettings       -- ^ Server configuration.
             -> [StratumQuery]       -- ^ Batch of queries.
             -> m [StratumResponse]  -- ^ Batch of responses (in any order).
queryStratumTCP cs qs = runStratumTCP False cs $ do
    rs <- mapM genReq qs
    st <- getStratumClient
    lift $ ConduitList.sourceList rs $$ stratumSink st
    lift $ stratumSrc st $= ConduitList.map msgToStratumResponse
                         $$ ConduitList.consume

-- | Execute Stratum TCP client.
runStratumTCP :: (MonadIO m, MonadBaseControl IO m)
              => Bool                -- ^ Handle notifications.
              -> ClientSettings      -- ^ TCP client settings data structure.
              -> StratumClient m a  -- ^ Computation to run.
              -> m a                 -- ^ Result from computation.
runStratumTCP n cs cl = do
    control $ \r -> do
        runTCPClient cs $ \ad -> do
            s <- sess
            let snk = transPipe liftIO $ reqConduit =$ appSink ad
                src = transPipe liftIO $ appSource ad $= ConduitBinary.lines
                    $= resConduit s
            r $ runReaderT cl (StratumClientStateTCP src snk, s)
  where
    sess | n = initSession $ Just parseNotif
         | otherwise = initSession Nothing
