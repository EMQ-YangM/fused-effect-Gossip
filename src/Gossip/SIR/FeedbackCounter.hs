{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

module Gossip.SIR.FeedbackCounter where

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

data PushReply
  = Push
  | Reply
  deriving (Show)

data Value
  = Value
  { _value :: String
  , _time  :: Int}
  | SV SIR
  deriving (Show, Eq, Ord)


makeLenses ''Value

update :: (HasLabelled NodeAction (NodeAction Value (PushReply, Value)) sig m)
       => Int
       -> Value
       -> m ()
update k v = do
  updateStore v
  putSIRState I
  putCounter k
  wait 1

loop :: (HasLabelled NodeAction (NodeAction Value (PushReply, Value)) sig m,
         Has Random sig m)
     => m ()
loop = do
  sir <- getSIRState
  when (sir == I) $ do
    peers <- getPeers
    p <- (`Set.elemAt` peers) <$> uniformR (0, Set.size peers - 1)
    value <- readStore
    sendMessage p (Push, value)
  wait 1
  loop

receive :: (HasLabelled NodeAction (NodeAction Value (PushReply, Value)) sig m)
        => Int
        -> m ()
receive k = do
  (si, (method, v)) <- readMessage
  case method of
    Push -> do
      sir <- getSIRState
      sendMessage si (Reply, SV sir)
      when (sir == S) $ do
        updateStore v
        putSIRState sir
        putCounter k
    Reply -> do
      case v of
        SV s -> do
          when (s /= S) $ do
            counter <- getCounter
            putCounter (counter -1)
            con1 <- getCounter
            when (con1 == 0) $ putSIRState Gossip.NodeAction.R
        _    -> error "never happened"

runS :: forall s. Int -> DiffTime -> StdGen -> ST s (SimTrace [(NodeId, Value)])
runS total time gen = runSimTraceST $ do
  let list = [0 .. total -1]
      k = 10
  ls <- forM list $ \i -> do
    tq <- newTQueueIO
    sirS <- newTVarIO S
    con <- newTVarIO 0
    ss <- newTVarIO (Value "0" 0)
    return ((NodeId i, tq), (sirS, (ss,con)))

  forM_  list $ \i -> do
    let ((a,b),(c,(d,e))) = ls !! i
        otherTQ = Map.fromList $ map (fst . (ls !!)) (L.delete i list)
        ns = NodeState a b otherTQ c d e
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(PushReply, Value) ns
         $ runRandom gen loop
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(PushReply, Value) ns (receive k)

    when (i `mod` 75 == 0)
      $ void
      $ forkIO
        $ void
        $ runNodeAction @(IOSim s) @Value @(PushReply, Value) ns (update k (Value (show i) i))

  threadDelay time
  forM ls $ \((nid, _),(_, (tv,_))) -> (nid,) <$> readTVarIO tv


runSim = do
  total <- getLine
  i <- randomIO
  case traceResult False $ runST $ runS (read total) 50 (mkStdGen i) of
    Left e -> print e
    Right l -> do
      let dis = foldl (\ m (k,v) -> Map.insertWith (+) v 1 m) Map.empty l
      print dis
  runSim




