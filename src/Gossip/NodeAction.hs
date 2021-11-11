{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

module Gossip.NodeAction where

import           Control.Algebra              hiding (send)
import           Control.Arrow                (Arrow (second))
import           Control.Carrier.Lift
import           Control.Carrier.Random.Gen
import           Control.Carrier.Reader
import           Control.Carrier.State.Strict
import           Control.Effect.IOClasses     (Algebra, DiffTime, IOSim,
                                               MonadDelay (threadDelay),
                                               MonadFork (forkIO),
                                               MonadST (withLiftST),
                                               MonadSTM (STM, atomically, newTQueueIO, readTVarIO),
                                               MonadSTMTx (TQueue_, TVar_, readTQueue, readTVar, writeTQueue, writeTVar),
                                               MonadSay (say),
                                               MonadTime (getCurrentTime),
                                               SimTrace, runSimTraceST,
                                               selectTraceEventsSay)
import           Control.Effect.Labelled      hiding (send)
import           Control.Effect.Sum           as S
import           Control.Monad
import           Data.ByteString
import           Data.Kind
import qualified Data.List                    as L
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import           Data.Set                     (Set)
import qualified Data.Set                     as Set
import           Data.Vector                  ((!))
import qualified Data.Vector                  as V
import           Gossip.Shuffle
import           Optics
import           System.Random                (mkStdGen)


newtype NodeId = NodeId Int deriving (Show, Read, Eq, Ord)

data SIR = I | R | S deriving (Eq, Ord, Show, Read)

data NodeState s value message
  = NodeState
  { _nodeId     :: NodeId
  , _inputQueue :: TQueue_ (STM s) (NodeId, message)
  , _peers      :: Map NodeId (TQueue_ (STM s) (NodeId, message))
  , _sirState   :: TVar_ (STM s) SIR
  , _store      :: TVar_ (STM s) value
  , _counter    :: TVar_ (STM s) Int
  }

makeLenses ''NodeState

data NodeAction s value message (m :: Type -> Type) a where
  SendMessage :: NodeId -> message -> NodeAction s value message m ()
  ReadMessage :: NodeAction s value message m (NodeId, message)
  InsertNode  :: NodeId -> TQueue_ (STM s) (NodeId, message) -> NodeAction s value message m ()
  DeleteNode :: NodeId -> NodeAction s value message m ()
  GetNodeId   :: NodeAction s value message m NodeId
  GetPeers    :: NodeAction s value message m (Set NodeId)
  Wait        :: DiffTime -> NodeAction s value message m ()
  GetSIRState :: NodeAction s value message m SIR
  PutSIRState :: SIR -> NodeAction s value message m ()
  ReadStore   :: NodeAction s value message m value
  UpdateStore :: value -> NodeAction s value message m ()
  GetCounter  :: NodeAction s value message m Int
  PutCounter  :: Int -> NodeAction s value message m ()

sendMessage :: HasLabelled NodeAction (NodeAction s value message) sig m => NodeId -> message -> m ()
sendMessage nid message = sendLabelled @NodeAction (SendMessage nid message)

readMessage :: HasLabelled NodeAction (NodeAction s value message) sig m => m (NodeId, message)
readMessage = sendLabelled @NodeAction ReadMessage

insertNode :: HasLabelled NodeAction (NodeAction s value message) sig m
           => NodeId
           -> TQueue_ (STM s) (NodeId, message)
           -> m ()
insertNode nid tq = sendLabelled @NodeAction (InsertNode nid tq)

deleteNode :: HasLabelled NodeAction (NodeAction s value message) sig m
           => NodeId
           -> m ()
deleteNode nid = sendLabelled @NodeAction (DeleteNode nid)

getNodeId :: HasLabelled NodeAction (NodeAction s value message) sig m => m NodeId
getNodeId = sendLabelled @NodeAction GetNodeId

getPeers :: HasLabelled NodeAction (NodeAction s value message) sig m => m (Set NodeId)
getPeers = sendLabelled @NodeAction GetPeers

wait :: HasLabelled NodeAction (NodeAction s value message) sig m => DiffTime -> m ()
wait df = sendLabelled @NodeAction (Wait df)

getSIRState :: HasLabelled NodeAction (NodeAction s value message) sig m => m SIR
getSIRState = sendLabelled @NodeAction GetSIRState

putSIRState :: HasLabelled NodeAction (NodeAction s value message) sig m => SIR -> m ()
putSIRState sir = sendLabelled @NodeAction (PutSIRState sir)

readStore :: HasLabelled NodeAction (NodeAction s value message) sig m => m value
readStore = sendLabelled @NodeAction ReadStore

updateStore :: HasLabelled NodeAction (NodeAction s value message) sig m => value -> m ()
updateStore message = sendLabelled @NodeAction (UpdateStore message)

getCounter :: HasLabelled NodeAction (NodeAction s value message) sig m => m Int
getCounter = sendLabelled @NodeAction GetCounter

putCounter :: HasLabelled NodeAction (NodeAction s value message) sig m => Int -> m ()
putCounter i = sendLabelled @NodeAction (PutCounter i)

newtype NodeActionC s value message m a =
  NodeActionC { runNodeActionC :: (StateC (NodeState s value message) m) a}
  deriving (Functor, Applicative ,Monad)

instance (Has (Lift s) sig m,
          MonadDelay s,
          MonadSay s,
          Show message,
          MonadTime s,
          MonadSTM s)
      => Algebra (NodeAction s value message :+: sig)
                 (NodeActionC s value message m) where
  alg hdl sig ctx = NodeActionC $ StateC $ \ns -> case sig of
    L (SendMessage nid message) -> do
      case ns ^. peers % at nid of
        Nothing -> undefined
        Just tq -> do
          sendM @s $ do
            time <- getCurrentTime
            say $ show (time, ns ^. nodeId, nid, message)
            say $ show time
              ++ " send message: "
              ++ show message
              ++ ". " ++ show (ns ^. nodeId)
              ++ "* -> " ++ show nid--
            atomically $ writeTQueue tq (ns ^. nodeId, message)
          pure (ns, ctx)
    L ReadMessage  -> do
      res <- sendM @s $  do
        res@(nid, message) <- atomically $ readTQueue (ns ^. inputQueue)
        say $ "read message: "
          ++ show message
          ++ ". " ++ show nid
          ++ " -> " ++ show (ns ^. nodeId) ++ "*"--
        return res
      pure (ns, res <$ ctx)
    L (InsertNode nid tq) -> do
      pure (ns & peers %~ Map.insert nid tq , ctx)
    L (DeleteNode nid) -> do
      pure (ns & peers %~ Map.delete nid , ctx)
    L GetNodeId -> pure (ns, ns ^. nodeId <$ ctx)
    L GetPeers -> pure (ns, Map.keysSet (ns ^. peers) <$ ctx)
    L (Wait df) -> sendM @s (threadDelay df) >> pure (ns, ctx)
    L GetSIRState -> sendM @s (readTVarIO (ns ^. sirState)) >>= \x -> pure (ns, x <$ ctx)
    L (PutSIRState sir) -> sendM @s (atomically $ writeTVar (ns ^. sirState) sir) >> pure (ns, ctx)
    L ReadStore ->  sendM @s (readTVarIO (ns ^. store)) >>= \res -> pure (ns, res <$ ctx)
    L (UpdateStore message) -> sendM @s (atomically $ writeTVar (ns ^. store) message) >> pure (ns, ctx)
    L GetCounter ->  sendM @s (readTVarIO (ns ^. counter)) >>= \res -> pure (ns, res <$ ctx)
    L (PutCounter message) -> sendM @s (atomically $ writeTVar (ns ^. counter) message) >> pure (ns, ctx)
    S.R other  -> thread (uncurry runState . second runNodeActionC ~<~ hdl) other (ns,ctx)


runNodeAction :: NodeState s value message
              -> Labelled NodeAction (NodeActionC s value message) m a
              -> m (NodeState s value message, a)
runNodeAction tq f = runState tq $ runNodeActionC $ runLabelled f
