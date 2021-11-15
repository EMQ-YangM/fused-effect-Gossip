{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}

module Gossip.Swim.Type where
import           Control.Algebra
import           Control.Carrier.State.Strict
import           Control.Effect.IOClasses     (DiffTime, MonadSTM (STM),
                                               MonadSTMTx (TQueue_))
import           Control.Effect.TH
import           Data.Kind
import           Data.Map                     (Map)
import           Data.Set                     (Set)
import           Optics

data Message
  = Ping
  | Ack
  | PingReq NodeId
  | Alive NodeId
  | Dead NodeId
  deriving (Show, Eq)

newtype NodeId = NodeId Int deriving (Show, Read, Eq, Ord)

data Channel m
  = Channel
  { send :: Message -> m (),
    recv :: m Message
  }

type DTQueue s = (TQueue_ (STM s) Message, TQueue_ (STM s) Message)

data NodeState s
  = NodeState
  { _nodeId :: NodeId
  , _peers  :: Map NodeId (DTQueue s)
  }

makeLenses ''NodeState

-- failureDetector

data NodeAction (m :: Type -> Type) a where
  SendMessage :: NodeId -> Message -> NodeAction m ()
  ReadMessage :: NodeId -> NodeAction m Message
  -- InsertNode  :: NodeId -> DTQ -> NodeAction m () ??? don't need insert node ???
  DeleteNode  :: NodeId -> NodeAction m ()
  PeekWithTimeout :: DiffTime -> NodeId -> Message -> NodeAction m (Maybe Bool)
  GetNodeId   :: NodeAction m NodeId
  GetPeers    :: NodeAction m (Set NodeId)
  Wait        :: DiffTime -> NodeAction m ()
  PeekSomeMessageFromAllPeersWithTimeout
    :: DiffTime
    -> [NodeId]
    -> Message
    -> NodeAction m (Maybe Bool)
  WaitAnyMessageFromAllPeers :: NodeAction m (NodeId, Message)
  ForkPingReqHandler :: NodeId -> DiffTime -> NodeId -> NodeAction m ()

makeSmartConstructors ''NodeAction
