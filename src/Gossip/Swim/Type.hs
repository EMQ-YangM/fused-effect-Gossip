{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

module Gossip.Swim.Type where
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
import           Data.ByteString              hiding (take)
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

data Message
  = Ping
  | Ack
  | PingReq NodeId
  | Alive NodeId
  | Dead NodeId

newtype NodeId = NodeId Int deriving (Show, Read, Eq, Ord)

type DTQueue s = (TQueue_ (STM s) Message, TQueue_ (STM s) Message)

data NodeState s
  = NodeState
  { _nodeId :: NodeId
  , _peers  :: Map NodeId (DTQueue s)
  }

makeLenses ''NodeState

data NodeAction s (m :: Type -> Type) a where

  SendMessage :: NodeId   -> Message -> NodeAction s m ()

  ReadMessage :: NodeId   -> NodeAction s m Message

  InsertNode  :: NodeId   -> DTQueue s -> NodeAction s m ()

  DeleteNode  :: NodeId   -> NodeAction s m ()

  PeekWithTimeout :: DiffTime -> NodeId -> NodeAction s m (Maybe a)

  GetNodeId   :: NodeAction s m NodeId

  GetPeers    :: NodeAction s m (Set NodeId)

  Wait        :: DiffTime -> NodeAction s m ()

  PeekSomeMessageFromAllPeersWithTimeout
    :: DiffTime
    -> [NodeId]
    -> message
    -> NodeAction s m (Maybe Bool)

  WaitAnyMessageFromAllPeers :: NodeAction s m (NodeId, Message)

  ForkPingReqHandler :: NodeId -> DiffTime -> NodeId -> NodeAction s m ()

sendMessage :: HasLabelled NodeAction (NodeAction s) sig m => NodeId -> Message -> m ()
sendMessage nid message = sendLabelled @NodeAction (SendMessage nid message)

readMessage :: HasLabelled NodeAction (NodeAction s) sig m => NodeId -> m Message
readMessage nid = sendLabelled @NodeAction (ReadMessage nid)

insertNode :: HasLabelled NodeAction (NodeAction s) sig m
           => NodeId
           -> DTQueue s
           -> m ()
insertNode nid tq = sendLabelled @NodeAction (InsertNode nid tq)

deleteNode :: HasLabelled NodeAction (NodeAction s) sig m
           => NodeId
           -> m ()
deleteNode nid = sendLabelled @NodeAction (DeleteNode nid)

peekWithTimeout :: HasLabelled NodeAction (NodeAction s) sig m
        => DiffTime
        -> NodeId
        -> m (Maybe a)
peekWithTimeout dt nid = sendLabelled @NodeAction (PeekWithTimeout dt nid)

getNodeId :: HasLabelled NodeAction (NodeAction s) sig m => m NodeId
getNodeId = sendLabelled @NodeAction GetNodeId

getPeers :: HasLabelled NodeAction (NodeAction s) sig m => m (Set NodeId)
getPeers = sendLabelled @NodeAction GetPeers

wait :: HasLabelled NodeAction (NodeAction s) sig m => DiffTime -> m ()
wait df = sendLabelled @NodeAction (Wait df)

peekSomeMessageFormAllPeersWithTimeout :: HasLabelled NodeAction (NodeAction s) sig m
                                       => DiffTime
                                       -> [NodeId]
                                       -> Message
                                       -> m (Maybe Bool)
peekSomeMessageFormAllPeersWithTimeout dt nids message =
  sendLabelled @NodeAction (PeekSomeMessageFromAllPeersWithTimeout dt nids message)

waitAnyMessageFromAllPeers :: HasLabelled NodeAction (NodeAction s) sig m
                           => m (NodeId, Message)
waitAnyMessageFromAllPeers = sendLabelled @NodeAction WaitAnyMessageFromAllPeers

forkPingReqHandler :: HasLabelled NodeAction (NodeAction s) sig m
                   => NodeId     -- ping node id
                   -> DiffTime   -- timeout time
                   -> NodeId     -- source node id
                   -> m ()
forkPingReqHandler nid' dt nid = sendLabelled @NodeAction (ForkPingReqHandler nid' dt nid)
