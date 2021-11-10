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
                                               UTCTime, diffUTCTime, ppTrace,
                                               runSimTraceST,
                                               selectTraceEventsSay,
                                               traceResult)
import           Control.Effect.Labelled
import           Control.Effect.Optics
import           Control.Monad
import           Control.Monad.ST.Lazy
import           Data.Function                ((&))
import qualified Data.List                    as L
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import qualified Data.Set                     as Set
import           Data.Vector                  ((!))
import           Gossip.NodeAction
import           Gossip.Shuffle
import           Optics                       (makeLenses, (^.))
import           System.Process
import           System.Random                (StdGen, mkStdGen, randomIO)

data PushReply
  = Push
  | Reply
  deriving (Show, Read)

data Value
  = Value
  { _value :: String}
  | SV SIR
  deriving (Show, Eq, Ord, Read)

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
        putSIRState I
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
  receive k

runS :: forall s. Int -> DiffTime -> Int -> ST s (SimTrace [(NodeId, Value)])
runS total time gen = runSimTraceST $ do
  let list = [0 .. total -1]
      k = 5
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
      runNodeAction @(IOSim s) @Value @(PushReply, Value) ns
         $ runRandom (mkStdGen (123 * i * gen + 123)) loop
    forkIO $ void $
      runNodeAction @(IOSim s) @Value @(PushReply, Value) ns (receive k)

    when (i == 1 )
      $ void
      $ forkIO
        $ void
        $ runNodeAction @(IOSim s) @Value @(PushReply, Value) ns (update k (Value (show i)))

  threadDelay time
  forM ls $ \((nid, _),(_, (tv,_))) -> (nid,) <$> readTVarIO tv

t0 = read "1970-01-01 00:00:00 UTC" :: UTCTime

-- res0 = selectTraceEventsSay  $ runST $ runS 10 4 10

handle (u,b,c,d) = (floor $ u `diffUTCTime` t0,b,c,d)

res i = selectTraceEventsSay (runST $ runS 30 30 i)
    & map (handle . read @(UTCTime, NodeId, NodeId, (PushReply, Value)))
    & foldl (\ m (a,b,c,d) -> Map.insertWith (++) a [(b,c,d)] m) Map.empty
    & Map.toList
    & map createDot

write :: IO ()
write = do
  gen <- randomIO
  forM_ (res gen) $ \(i, s) -> do
    let basePath = "./dot/time" ++ show i
    writeFile (basePath ++ ".dot") (wrapper s)
    system $ "dot -Tpng -o " ++ basePath ++ ".png " ++ basePath ++ ".dot"

  system "eog ./dot/time1.png"
  return ()

    -- return a

wrapper :: [String] -> String
wrapper ss = unlines [
  "digraph time1 {",
  unlines ss,
  "}"
                    ]

replcaeSpace :: Char -> Char
replcaeSpace ' ' = '_'
replcaeSpace c   = c

render' ::  Value -> String
render' (SV sir)    = show sir
render' (Value v) = v

renderPushReply :: PushReply -> String
renderPushReply Push  = "Push"
renderPushReply Reply = "Reply"

render :: (PushReply, Value) -> String
render (a,b) = renderPushReply a ++ ", " ++ render' b

createDot :: (Integer, [(NodeId, NodeId, (PushReply, Value))]) -> (Integer, [String])
createDot (i, ls) =
  let a = map (\(a,b,c) -> map replcaeSpace (show a)
                        ++ " -> "
                        ++ map replcaeSpace (show b)
                        ++ "[label=\""
                        ++ map replcaeSpace (render c)
                        ++ "\"]"
              ) ls
  in  (i, a)

runSim = do
  total <- getLine
  i <- randomIO
  case traceResult False $ runST $ runS (read total) 20 i of
    Left e -> print e
    Right l -> do
      let dis = foldl (\ m (k,v) -> Map.insertWith (+) v 1 m) Map.empty l
      print dis
  runSim




