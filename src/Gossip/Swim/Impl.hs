{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DataKinds                  #-}
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

module Gossip.Swim.Impl where
import           Control.Algebra              (send)
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
import           Control.Monad
import           Data.ByteString              hiding (getLine, take)
import           Data.Kind
import qualified Data.List                    as L
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import           Data.Set                     (Set)
import qualified Data.Set                     as Set
import           Data.Vector                  ((!))
import qualified Data.Vector                  as V
import           Gossip.Shuffle
import           Gossip.Swim.Type
import           Optics
import           Unsafe.Coerce

newtype NodeActionC s a = NodeActionC {runNodeActionC :: StateC (NodeState s) s a}
  deriving (Functor, Applicative, Monad)

instance Monad s => Algebra NodeAction (NodeActionC s) where
  alg hdl sig ctx = undefined

runNodeAction :: NodeState s -> NodeActionC s a -> s (NodeState s, a)
runNodeAction tq f = runState tq $ runNodeActionC f

foo1 :: (Has (NodeAction :+: State Int) sig m)
     => m ()
foo1 = do
  sendMessage (NodeId 10) Ping
  put @Int 10

runFoo1 = runNodeAction @IO undefined
        $ runState @Int 0 foo1

