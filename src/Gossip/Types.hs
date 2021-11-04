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

module Gossip.Types where

import           Control.Algebra
import           Control.Arrow                  (Arrow (second))
import           Control.Carrier.Lift
import           Control.Carrier.Random.Gen
import           Control.Carrier.Reader
import           Control.Carrier.State.Strict
import           Control.Effect.IOClasses       (Algebra, DiffTime, IOSim,
                                                 MonadDelay (threadDelay),
                                                 MonadFork (forkIO),
                                                 MonadSTM (STM, atomically, newTQueueIO),
                                                 MonadSTMTx (TQueue_, readTQueue, writeTQueue),
                                                 MonadSay (say), SimTrace,
                                                 runSimTraceST,
                                                 selectTraceEventsSay)
import           Control.Effect.Labelled
import           Control.Effect.Reader.Labelled (HasLabelled)
import           Control.Monad
import           Control.Monad.ST.Lazy
import           Data.Kind
import qualified Data.List                      as L
import           Data.Map                       (Map)
import qualified Data.Map                       as Map
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Optics
import           System.Random                  (mkStdGen)

newtype NodeId = NodeId Int deriving (Show, Eq, Ord)

data NodeState s message
  = NodeState
  { _nodeId     :: NodeId
  , _inputQueue :: TQueue_ (STM s) (NodeId, message)
  , _peers      :: Map NodeId (TQueue_ (STM s) (NodeId, message))
  }

makeLenses ''NodeState

data NodeAction message (m :: Type -> Type) a where
  SendMessage :: NodeId -> message -> NodeAction message m ()
  ReadMessage :: NodeAction message m (NodeId, message)
  GetNodeId :: NodeAction message m NodeId
  GetPeers :: NodeAction message m (Set NodeId)
  Wait :: DiffTime -> NodeAction message m ()

sendMessage :: HasLabelled NodeAction (NodeAction message) sig m => NodeId -> message -> m ()
sendMessage nid message = sendLabelled @NodeAction (SendMessage nid message)

readMessage :: HasLabelled NodeAction (NodeAction message) sig m => m (NodeId, message)
readMessage = sendLabelled @NodeAction ReadMessage

getNodeId :: HasLabelled NodeAction (NodeAction message) sig m => m NodeId
getNodeId = sendLabelled @NodeAction GetNodeId

getPeers :: HasLabelled NodeAction (NodeAction message) sig m => m (Set NodeId)
getPeers = sendLabelled @NodeAction GetPeers


wait :: HasLabelled NodeAction (NodeAction message) sig m => DiffTime -> m ()
wait df = sendLabelled @NodeAction (Wait df)

newtype NodeActionC s message m a =
  NodeActionC { runNodeActionC :: (StateC (NodeState s message) m) a}
  deriving (Functor, Applicative ,Monad)

instance (Has (Lift s) sig m,
          MonadDelay s,
          MonadSay s,
          Show message,
          MonadSTM s)
      => Algebra (NodeAction message :+: sig)
                 (NodeActionC s message m) where
  alg hdl sig ctx = NodeActionC $ StateC $ \ns -> case sig of
    L (SendMessage nid message) -> do
      case ns ^. peers % at nid of
        Nothing -> undefined
        Just tq -> do
          sendM @s $ do
            say $ "send message: "
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
    R other  -> thread (uncurry runState . second runNodeActionC ~<~ hdl) other (ns,ctx)


runNodeAction :: NodeState s message
              -> Labelled NodeAction (NodeActionC s message) m a
              -> m (NodeState s message, a)
runNodeAction tq f = runState tq $ runNodeActionC $ runLabelled f

example :: (HasLabelled NodeAction (NodeAction message) sig m, Eq message,
            Has (Random :+: State message :+: State (Set NodeId)) sig m)
        => m ()
example = do
  (sid, message) <- readMessage
  originMessage <- get
  if message == originMessage
    then return ()
    else do
      put message
      peers <- getPeers
      put (Set.delete sid peers)
      let loop = do
            nidSet <- get @(Set NodeId)
            if Set.null nidSet
              then return ()
              else do
                nids <- getRandom @NodeId 3
                forM_ nids $ \nid -> do
                  sendMessage nid message
                wait 1
                loop
      loop

getRandom :: forall s sig m.
             Has (Random :+: State (Set s)) sig m
          => Int -- number
          -> m [s]
getRandom number = do
  s <- get @(Set s)
  let total = Set.size s
  if total < number
    then put @(Set s) Set.empty >> pure (Set.toList s)
    else do
      r <- replicateM number $ uniformR (0, total - 1)
      forM (L.nub r) $ \i -> do
        put (Set.deleteAt i s)
        pure (Set.elemAt i s)

runIO :: IO ()
runIO = do
  tq0 <- newTQueueIO
  tq1 <- newTQueueIO
  tq2 <- newTQueueIO
  tq3 <- newTQueueIO
  let nid0 = NodeId 0
      nid1 = NodeId 1
      nid2 = NodeId 2
      nid3 = NodeId 3

  atomically $ writeTQueue tq1 (nid0, "start")

  forkIO $ void
     $ runNodeAction @IO @String (NodeState nid3 tq3 (Map.singleton nid0 tq0))
     $ runState @String ""
     $ runState @(Set NodeId) Set.empty
     $ runRandom (mkStdGen 10) example

  forkIO $ void
     $ runNodeAction @IO @String (NodeState nid2 tq2 (Map.singleton nid3 tq3))
     $ runState @String ""
     $ runState @(Set NodeId) Set.empty
     $ runRandom (mkStdGen 10) example

  runNodeAction @IO @String (NodeState nid1 tq1 (Map.singleton nid2 tq2))
     $ runState @String ""
     $ runState @(Set NodeId) Set.empty
     $ runRandom (mkStdGen 10) example

  return ()



runIOSim :: forall s. ST s (SimTrace ())
runIOSim = runSimTraceST $ do
  tq0 <- newTQueueIO
  tq1 <- newTQueueIO
  tq2 <- newTQueueIO
  tq3 <- newTQueueIO
  let nid0 = NodeId 0
      nid1 = NodeId 1
      nid2 = NodeId 2
      nid3 = NodeId 3

  atomically $ writeTQueue tq1 (nid0, "start")

  forkIO $ void
     $ runNodeAction @(IOSim s) @String (NodeState nid3 tq3 (Map.singleton nid0 tq0))
     $ runState @String ""
     $ runState @(Set NodeId) Set.empty
     $ runRandom (mkStdGen 10) example

  forkIO $ void
     $ runNodeAction @(IOSim s) @String (NodeState nid2 tq2 (Map.singleton nid3 tq3))
     $ runState @String ""
     $ runState @(Set NodeId) Set.empty
     $ runRandom (mkStdGen 10) example

  runNodeAction @(IOSim s) @String (NodeState nid1 tq1 (Map.singleton nid2 tq2))
     $ runState @String ""
     $ runState @(Set NodeId) Set.empty
     $ runRandom (mkStdGen 10) example

  return ()


runSim1 = runST runIOSim
