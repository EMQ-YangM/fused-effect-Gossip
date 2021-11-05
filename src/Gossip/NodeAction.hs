{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

module Gossip.NodeAction where

import           Control.Algebra
import           Control.Arrow                  (Arrow (second))
import           Control.Carrier.Lift
import           Control.Carrier.Random.Gen
import           Control.Carrier.Reader
import           Control.Carrier.State.Strict
import           Control.Effect.IOClasses       (Algebra, DiffTime, IOSim,
                                                 MonadDelay (threadDelay),
                                                 MonadFork (forkIO),
                                                 MonadSTM (STM, atomically, newTQueueIO, readTVarIO),
                                                 MonadSTMTx (TQueue_, TVar_, readTQueue, readTVar, writeTQueue, writeTVar),
                                                 MonadSay (say),
                                                 MonadTime (getCurrentTime),
                                                 SimTrace, runSimTraceST,
                                                 selectTraceEventsSay)
import           Control.Effect.Labelled
import           Control.Effect.Reader.Labelled (HasLabelled)
import           Control.Effect.Sum             as S
import           Control.Monad
import           Control.Monad.ST.Lazy
import           Data.Kind
import qualified Data.List                      as L
import           Data.Map                       (Map)
import qualified Data.Map                       as Map
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Data.Vector                    ((!))
import qualified Data.Vector                    as V
import           Gossip.Shuffle
import           Optics
import           System.Random                  (mkStdGen)

newtype NodeId = NodeId Int deriving (Show, Eq, Ord)

data SIR = I | R | S deriving (Eq)

data NodeState s value message
  = NodeState
  { _nodeId     :: NodeId
  , _inputQueue :: TQueue_ (STM s) (NodeId, message)
  , _peers      :: Map NodeId (TQueue_ (STM s) (NodeId, message))
  , _sirState   :: TVar_ (STM s) SIR
  , _store      :: TVar_ (STM s) value
  }

makeLenses ''NodeState

data NodeAction value message (m :: Type -> Type) a where
  SendMessage :: NodeId -> message -> NodeAction value message m ()
  ReadMessage :: NodeAction value message m (NodeId, message)
  GetNodeId   :: NodeAction value message m NodeId
  GetPeers    :: NodeAction value message m (Set NodeId)
  Wait        :: DiffTime -> NodeAction value message m ()
  GetSIRState :: NodeAction value message m SIR
  PutSIRState :: SIR -> NodeAction value message m ()
  ReadStore   :: NodeAction value message m value
  UpdateStore :: value -> NodeAction value message m ()

sendMessage :: HasLabelled NodeAction (NodeAction value message) sig m => NodeId -> message -> m ()
sendMessage nid message = sendLabelled @NodeAction (SendMessage nid message)

readMessage :: HasLabelled NodeAction (NodeAction value message) sig m => m (NodeId, message)
readMessage = sendLabelled @NodeAction ReadMessage

getNodeId :: HasLabelled NodeAction (NodeAction value message) sig m => m NodeId
getNodeId = sendLabelled @NodeAction GetNodeId

getPeers :: HasLabelled NodeAction (NodeAction value message) sig m => m (Set NodeId)
getPeers = sendLabelled @NodeAction GetPeers

wait :: HasLabelled NodeAction (NodeAction value message) sig m => DiffTime -> m ()
wait df = sendLabelled @NodeAction (Wait df)

getSIRState :: HasLabelled NodeAction (NodeAction value message) sig m => m SIR
getSIRState = sendLabelled @NodeAction GetSIRState

putSIRState :: HasLabelled NodeAction (NodeAction value message) sig m => SIR -> m ()
putSIRState sir = sendLabelled @NodeAction (PutSIRState sir)

readStore :: HasLabelled NodeAction (NodeAction value message) sig m => m value
readStore = sendLabelled @NodeAction ReadStore

updateStore :: HasLabelled NodeAction (NodeAction value message) sig m => value -> m ()
updateStore message = sendLabelled @NodeAction (UpdateStore message)

newtype NodeActionC s value message m a =
  NodeActionC { runNodeActionC :: (StateC (NodeState s value message) m) a}
  deriving (Functor, Applicative ,Monad)

instance (Has (Lift s) sig m,
          MonadDelay s,
          MonadSay s,
          Show message,
          MonadTime s,
          MonadSTM s)
      => Algebra (NodeAction value message :+: sig)
                 (NodeActionC s value message m) where
  alg hdl sig ctx = NodeActionC $ StateC $ \ns -> case sig of
    L (SendMessage nid message) -> do
      case ns ^. peers % at nid of
        Nothing -> undefined
        Just tq -> do
          sendM @s $ do
            time <- getCurrentTime
            say $ show time
              ++ " send message: "
              ++ show message
              ++ ". " ++ show (ns ^. nodeId)
              ++ "* -> " ++ show nid
            atomically $ writeTQueue tq (ns ^. nodeId, message)
          pure (ns, ctx)
    L ReadMessage  -> do
      res <- sendM @s $  do
        res@(nid, message) <- atomically $ readTQueue (ns ^. inputQueue)
        say $ "read message: "
          ++ show message
          ++ ". " ++ show nid
          ++ " -> " ++ show (ns ^. nodeId) ++ "*"
        return res
      pure (ns, res <$ ctx)
    L GetNodeId -> pure (ns, ns ^. nodeId <$ ctx)
    L GetPeers -> pure (ns, Map.keysSet (ns ^. peers) <$ ctx)
    L (Wait df) -> sendM @s (threadDelay df) >> pure (ns, ctx)
    L GetSIRState -> sendM @s (readTVarIO (ns ^. sirState)) >>= \x -> pure (ns, x <$ ctx)
    L (PutSIRState sir) -> sendM @s (atomically $ writeTVar (ns ^. sirState) sir) >> pure (ns, ctx)
    L ReadStore ->  sendM @s (readTVarIO (ns ^. store)) >>= \res -> pure (ns, res <$ ctx)
    L (UpdateStore message) -> sendM @s (atomically $ writeTVar (ns ^. store) message) >> pure (ns, ctx)
    S.R other  -> thread (uncurry runState . second runNodeActionC ~<~ hdl) other (ns,ctx)


runNodeAction :: NodeState s value message
              -> Labelled NodeAction (NodeActionC s value message) m a
              -> m (NodeState s value message, a)
runNodeAction tq f = runState tq $ runNodeActionC $ runLabelled f
