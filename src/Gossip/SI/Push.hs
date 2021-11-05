{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

module Gossip.SI.Push where

import           Control.Algebra
import           Control.Carrier.Random.Gen
import           Control.Carrier.State.Strict
import           Control.Effect.IOClasses     (IOSim, MonadDelay (threadDelay),
                                               MonadFork (forkIO),
                                               MonadSTM (STM, newTQueueIO, newTVarIO, readTVarIO),
                                               MonadSTMTx (TQueue_),
                                               MonadSay (say), SimTrace,
                                               runSimTraceST, DiffTime,
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
import           System.Random                (mkStdGen, StdGen, randomIO)

data Push = Push deriving (Show)
data Value
  = Value
  { _value :: String
  , _time  :: Int
  } deriving (Show, Eq, Ord)

makeLenses ''Value

loop :: (HasLabelled NodeAction (NodeAction Value (Push, Value)) sig m,
            Has Random sig m)
     => m ()
loop = do
  peers <- getPeers
  q <- (`Set.elemAt` peers) <$> uniformR (0, Set.size peers - 1)
  value <- readStore
  sendMessage q (Push, value)
  wait 1
  loop

receive :: (HasLabelled NodeAction (NodeAction Value (Push, Value)) sig m)
        => m ()
receive = do
  (sid, (Push, v)) <- readMessage
  value <- readStore
  when (value ^. time < v ^. time) $ updateStore v
  receive
