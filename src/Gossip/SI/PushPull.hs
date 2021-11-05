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

runIO1 = runIO 2000 4 (mkStdGen 10)

runIO :: Int -> DiffTime -> StdGen -> IO ()
runIO total time gen = do
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
      runNodeAction @IO @Value @(PushPull, ValueOrTime) ns
         $ runRandom gen loop
    forkIO $ void $
      runNodeAction @IO @Value @(PushPull, ValueOrTime) ns receive
  threadDelay time
  l <- forM ls $ \((nid, _),(_, tv)) -> (nid,) <$> readTVarIO tv
  let dis = foldl (\ m (k,v) -> Map.insertWith (+) v 1 m) Map.empty l
  print dis


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
      runNodeAction @(IOSim s) @Value @(PushPull, ValueOrTime) ns
         $ runRandom gen loop
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(PushPull, ValueOrTime) ns receive
  threadDelay time
  forM ls $ \((nid, _),(_, tv)) -> (nid,) <$> readTVarIO tv


runSim = do
  total <- getLine
  i <- randomIO
  case traceResult False $ runST $ runS (read total) 5 (mkStdGen i) of
    Left e -> print e
    Right l -> do
      let dis = foldl (\ m (k,v) -> Map.insertWith (+) v 1 m) Map.empty l
      print dis
  runSim













