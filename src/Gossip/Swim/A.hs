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


module Gossip.Swim.A where
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
                                               MonadTimer, SimTrace,
                                               runSimTraceST,
                                               selectTraceEventsSay)
import qualified Control.Effect.IOClasses     as IOC
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


data Message
  = Ping
  | Ack
  | PingReq NodeId
  | Alive NodeId
  | Dead NodeId

newtype NodeId = NodeId Int deriving (Show, Read, Eq, Ord)

type DTQueue s message = (TQueue_ (STM s) message, TQueue_ (STM s) message)

data NodeState s value message
  = NodeState
  { _nodeId :: NodeId
  , _peers  :: Map NodeId (DTQueue s message)
  }

makeLenses ''NodeState

data NodeAction s message (m :: Type -> Type) a where

  SendMessage :: NodeId   -> message -> NodeAction s message m ()

  ReadMessage :: NodeId   -> NodeAction s message m message

  InsertNode  :: NodeId   -> DTQueue s message -> NodeAction s message m ()

  DeleteNode  :: NodeId   -> NodeAction s message m ()

  Timeout     :: DiffTime -> m a -> NodeAction s massage m (Maybe a)

  GetNodeId   :: NodeAction s message m NodeId

  GetPeers    :: NodeAction s message m (Set NodeId)

  Wait        :: DiffTime -> NodeAction s message m ()

sendMessage :: HasLabelled NodeAction (NodeAction s message) sig m => NodeId -> message -> m ()
sendMessage nid message = sendLabelled @NodeAction (SendMessage nid message)

readMessage :: HasLabelled NodeAction (NodeAction s message) sig m => NodeId -> m message
readMessage nid = sendLabelled @NodeAction (ReadMessage nid)

insertNode :: HasLabelled NodeAction (NodeAction s message) sig m
           => NodeId
           -> DTQueue s message
           -> m ()
insertNode nid tq = sendLabelled @NodeAction (InsertNode nid tq)

deleteNode :: HasLabelled NodeAction (NodeAction s message) sig m
           => NodeId
           -> m ()
deleteNode nid = sendLabelled @NodeAction (DeleteNode nid)

timeout :: HasLabelled NodeAction (NodeAction s message) sig m
        => DiffTime
        -> m a
        -> m (Maybe a)
timeout dt action = sendLabelled @NodeAction (Timeout dt action)

getNodeId :: HasLabelled NodeAction (NodeAction s message) sig m => m NodeId
getNodeId = sendLabelled @NodeAction GetNodeId

getPeers :: HasLabelled NodeAction (NodeAction s message) sig m => m (Set NodeId)
getPeers = sendLabelled @NodeAction GetPeers

wait :: HasLabelled NodeAction (NodeAction s message) sig m => DiffTime -> m ()
wait df = sendLabelled @NodeAction (Wait df)

------------------------------------------------------------------------
failuerDetector :: (HasLabelled NodeAction (NodeAction s Message) sig m,
                    Has (Random :+: State Int) sig m)
                => NodeId
                -> m ()
failuerDetector nid = do
  sendMessage nid Ping
  message <- timeout 1 (readMessage nid)
  case message of
    Just v -> case v of
      Ack -> pure ()
      _   -> error "never happened"
    Nothing  -> do
      peers <- getPeers
      forM_ (Set.toList peers) $ \id -> do
        sendMessage id (PingReq id)
      -- TODO: wait for any response
      undefined
