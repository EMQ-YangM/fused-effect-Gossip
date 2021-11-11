{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE RecordWildCards     #-}
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

newtype Value
  = Value
  { _value :: String
  } deriving (Show, Eq, Ord)

makeLenses ''Value

update :: (HasLabelled NodeAction (NodeAction s Value (Push, Value)) sig m)
       => Value
       -> m ()
update v@Value{..} = do
  updateStore v
  putSIRState I

loop :: (HasLabelled NodeAction (NodeAction s Value (Push, Value)) sig m,
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

receive :: (HasLabelled NodeAction (NodeAction s Value (Push, Value)) sig m)
        => m ()
receive = do
  (sid, (Push, v)) <- readMessage
  sir <- getSIRState
  when (sir == S) $ do
    updateStore v
    putSIRState I
  receive

runS :: forall s. Double -> Int -> DiffTime -> Int -> ST s (SimTrace [(NodeId, Value)])
runS rrrr total time gen = runSimTraceST $ do
  let list = [0 .. total -1]
  ls <- forM list $ \i -> do
    tq <- newTQueueIO
    sirS <- newTVarIO S
    con <- newTVarIO 0
    ss <- newTVarIO (Value "0")
    return ((NodeId i, tq), (sirS, (ss,con)))

  forM_  list $ \i -> do
    let ((a,b),(c,(d,e))) = ls !! i
        otherTQ = Map.fromList $ map (fst . (ls !!)) (L.delete i list)
        ns = NodeState a b otherTQ c d e
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(Push, Value) ns
         $ runRandom (mkStdGen $ gen * 1231 * i) (loop rrrr)
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(Push, Value) ns receive

    when (i == 1)
      $ void
      $ forkIO
        $ void
        $ runNodeAction @(IOSim s) @Value @(Push, Value) ns (update (Value (show i)))

  threadDelay time
  forM ls $ \((nid, _),(_, (tv,_))) -> (nid,) <$> readTVarIO tv


runSim = do
  input <- getLine
  let a:b:c:_ = words input
      total = read a
      rrrr = read b -- feq
      cycle = read c :: Int
  print (a,b,c)
  forM_ [1..20] $ \_ -> do
    i <- randomIO
    case traceResult False $ runST $ runS rrrr total (fromIntegral cycle) i of
      Left e -> print e
      Right l -> do
        let dis = foldl (\ m (k,v) -> Map.insertWith (+) v 1 m) Map.empty l
        print dis
  runSim

