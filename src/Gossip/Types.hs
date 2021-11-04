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
                                                 MonadSay (say),
                                                 MonadTime (getCurrentTime),
                                                 SimTrace, runSimTraceST,
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
import           Data.Vector                    ((!))
import qualified Data.Vector                    as V
import           Gossip.Shuffle
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
          MonadTime s,
          MonadSTM s)
      => Algebra (NodeAction message :+: sig)
                 (NodeActionC s message m) where
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
    R other  -> thread (uncurry runState . second runNodeActionC ~<~ hdl) other (ns,ctx)


runNodeAction :: NodeState s message
              -> Labelled NodeAction (NodeActionC s message) m a
              -> m (NodeState s message, a)
runNodeAction tq f = runState tq $ runNodeActionC $ runLabelled f

example :: (HasLabelled NodeAction (NodeAction message) sig m, Eq message,
            Has (Random :+: State message) sig m)
        => m ()
example = do
  (sid, message) <- readMessage
  originMessage <- get
  if message == originMessage
    then return ()
    else do
      put message

      peers <- getPeers

      g <- mkStdGen <$> uniform

      let newPeers = Set.delete sid peers -- delete sender id

          size = Set.size newPeers  -- get size

          shuVec = shuffleVec size g -- genrate shuffle (Vecter Int)

          loop [] = return ()
          loop nids = do
                wait 1
                let (ll, lr) = splitAt 3 nids
                forM_ ll $ \index -> do
                  sendMessage (Set.elemAt (shuVec ! index) newPeers) message
                loop lr

      loop [0 .. size -1]


runIO :: IO ()
runIO = do
  let number = 10
  ls <- forM [0 .. number -1] $ \i -> do
    tq <- newTQueueIO
    return (NodeId i, tq)

  forM_ [1 .. number - 1] $ \i -> do
    let (ni,tqi) = ls !! i
        (niNext, tqiNext) = ls !! ((i + 1) `mod` number)
    forkIO $ void
       $ runNodeAction @IO @String (NodeState ni tqi (Map.singleton niNext tqiNext))
       $ runState @String ""
       $ runRandom (mkStdGen 10) example

  let (ni0,tqi0) = head ls
      (ni1,tqi1) = ls !! 1
  atomically $ writeTQueue tqi1 (ni0, "start")

  atomically $ readTQueue tqi0
  return ()


runIOSim :: forall s. ST s (SimTrace ())
runIOSim = runSimTraceST $ do
  let number = 10
  ls <- forM [0 .. number -1] $ \i -> do
    tq <- newTQueueIO
    return (NodeId i, tq)

  forM_ [1 .. number - 1] $ \i -> do
    let (ni,tqi) = ls !! i
        (niNext, tqiNext) = ls !! ((i + 1) `mod` number)
    forkIO $ void
       $ runNodeAction @(IOSim s) @String (NodeState ni tqi (Map.singleton niNext tqiNext))
       $ runState @String ""
       $ runRandom (mkStdGen 10) example

  let (ni0,tqi0) = head ls
      (ni1,tqi1) = ls !! 1
  atomically $ writeTQueue tqi1 (ni0, "start")

  atomically $ readTQueue tqi0
  return ()

runSim1 = selectTraceEventsSay $ runST runIOSim
