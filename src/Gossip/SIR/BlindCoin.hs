{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

module Gossip.SIR.BlindCoin where

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

data Push
  = Push
  deriving (Show)

data Value
  = Value
  { _value :: String
  , _time  :: Int
  } deriving (Show, Eq, Ord)

makeLenses ''Value

update :: (HasLabelled NodeAction (NodeAction Value (Push, Value)) sig m)
       => Value
       -> m ()
update v = do
  putSIRState I
  updateStore v
  wait 1

loop :: (HasLabelled NodeAction (NodeAction Value (Push, Value)) sig m,
         Has Random sig m)
     => Double
     -> m ()
loop k = do
  sir <- getSIRState
  when (sir == I) $ do
      peers <- getPeers
      q <- (`Set.elemAt` peers) <$> uniformR (0, Set.size peers - 1)
      value <- readStore
      sendMessage q (Push, value)
      rv <- uniformR @Double (0, 1)
      when (rv < 1 / k) $ do
        putSIRState Gossip.NodeAction.R

  wait 1
  loop k

receive :: (HasLabelled NodeAction (NodeAction Value (Push, Value)) sig m)
        => m ()
receive = do
  (sid, (Push, v)) <- readMessage
  sir <- getSIRState
  when (sir == S) $ do
    updateStore v
    putSIRState I
  receive

runS :: forall s. Int -> DiffTime -> StdGen -> ST s (SimTrace [(NodeId, Value)])
runS total time gen = runSimTraceST $ do
  let list = [0 .. total -1]
  ls <- forM list $ \i -> do
    tq <- newTQueueIO
    sirS <- newTVarIO S
    ss <- newTVarIO (Value "0" 0)
    return ((NodeId i, tq), (sirS, ss))

  forM_  list $ \i -> do
    let ((a,b),(c,d)) = ls !! i
        otherTQ = Map.fromList $ map (fst . (ls !!)) (L.delete i list)
        ns = NodeState a b otherTQ c d
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(Push, Value) ns
         $ runRandom gen (loop 60)
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(Push, Value) ns receive

    when (i `mod` 75 == 0)
      $ void
      $ forkIO
        $ void
        $ runNodeAction @(IOSim s) @Value @(Push, Value) ns (update (Value (show i) i))

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

