{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

module Gossip.SI.PushPull where

import           Control.Algebra
import           Control.Carrier.Random.Gen
import           Control.Carrier.State.Strict
import           Control.Effect.IOClasses     (DiffTime, IOSim,
                                               MonadDelay (threadDelay),
                                               MonadFork (forkIO),
                                               MonadSTM (STM, newTQueueIO, newTVarIO, readTVarIO),
                                               MonadSTMTx (TQueue_),
                                               MonadSay (say), SimTrace,
                                               runSimTraceST,
                                               selectTraceEventsSay,
                                               traceResult)
import           Control.Effect.Labelled
import           Control.Effect.Optics
import           Control.Monad
import           Control.Monad.ST.Lazy
import qualified Data.List                    as L
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import qualified Data.Set                     as Set
import           Data.Vector                  ((!))
import           Gossip.NodeAction
import           Gossip.Shuffle
import           Optics                       (makeLenses, (^.))
import           System.Random                (StdGen, mkStdGen, randomIO)

data PushPull
  = PushPull
  | Reply
  deriving (Show)

data ValueOrTime = T Int  | V Value deriving (Show)

data Value
  = Value
  { _value :: String
  , _time  :: Int
  } deriving (Show, Eq, Ord)

makeLenses ''Value


loop :: (HasLabelled NodeAction (NodeAction Value (PushPull, ValueOrTime)) sig m,
            Has Random sig m)
     => m ()
loop = do
  peers <- getPeers
  q <- (`Set.elemAt` peers) <$> uniformR (0, Set.size peers - 1)
  value <- readStore
  sendMessage q (PushPull, V value)
  wait 1
  loop


receive :: (HasLabelled NodeAction (NodeAction Value (PushPull, ValueOrTime)) sig m)
        => m ()
receive = do
  (sid, (method, v)) <- readMessage
  value <- readStore
  case (method, v) of
    (PushPull, V v) -> do
      if value ^. time < v ^. time
        then updateStore v
        else when (value ^. time > v ^. time) $ sendMessage sid (Reply, V value)
    (Reply,V v)     -> when (value ^. time < v ^. time) $ updateStore v
    _               -> error "never happened"
  receive

