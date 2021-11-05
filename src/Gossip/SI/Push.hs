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

runIO :: IO ()
runIO = do
  let list = [0 .. 10]
  ls <- forM list $ \i -> do
    tq <- newTQueueIO
    sirS <- newTVarIO S
    ss <- newTVarIO (Value "" 0)
    return ((NodeId i, tq), (sirS, ss))

  forM_  list $ \i -> do
    let ((a,b),(c,d)) = ls !! i
        otherTQ = Map.fromList $ map (fst . (ls !!)) (L.delete i list)
        ns = NodeState a b otherTQ c d
    forkIO $ void $
      runNodeAction @IO @Value @(Push, Value) ns
         $ runRandom (mkStdGen 10) loop
    forkIO $ void $
      runNodeAction @IO @Value @(Push, Value) ns receive
  threadDelay 5
  res <- forM ls $ \(_,(_, tv)) -> readTVarIO tv
  say (show res)



runS :: forall s. Int -> DiffTime -> StdGen -> ST s (SimTrace [(NodeId, Value)])
runS total time gen = runSimTraceST $ do
  let list = [0 .. total -1]
  ls <- forM list $ \i -> do
    tq <- newTQueueIO
    sirS <- newTVarIO S
    ss <- newTVarIO (Value (show i) i)
    return ((NodeId i, tq), (sirS, ss))

  forM_  list $ \i -> do
    let ((a,b),(c,d)) = ls !! i
        otherTQ = Map.fromList $ map (fst . (ls !!)) (L.delete i list)
        ns = NodeState a b otherTQ c d
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(Push, Value) ns
         $ runRandom gen loop
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(Push, Value) ns receive
  threadDelay time
  forM ls $ \((nid, _),(_, tv)) -> (nid,) <$> readTVarIO tv


runSim = do
  total <- getLine
  i <- randomIO
  case traceResult False $ runST $ runS (read total) 30 (mkStdGen i) of
    Left e -> print e
    Right l -> do
      let dis = foldl (\ m (k,v) -> Map.insertWith (+) v 1 m) Map.empty l
      print dis
  runSim
