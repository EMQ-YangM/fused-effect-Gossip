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
{-# LANGUAGE TupleSections              #-}
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
                                               MonadSTMTx (TQueue_, TVar_, peekTQueue, readTQueue, readTVar, retry, writeTBQueue, writeTQueue, writeTVar),
                                               MonadSay (say),
                                               MonadTime (getCurrentTime),
                                               MonadTimer (timeout), SimTrace,
                                               runSimTraceST,
                                               selectTraceEventsSay)
-- import qualified Control.Effect.IOClasses     as IOC
import           Control.Applicative
import           Control.Monad
import           Data.ByteString              hiding (foldr, getLine, take)
import           Data.Kind
import qualified Data.List                    as L
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import           Data.Maybe                   (fromMaybe)
import           Data.Set                     (Set)
import qualified Data.Set                     as Set
import           Data.Vector                  ((!))
import qualified Data.Vector                  as V
import           Gossip.Shuffle
import           Gossip.Swim.Type
import           Optics                       ((%~), (&), (^.))

newtype NodeActionC s a = NodeActionC {runNodeActionC :: StateC (NodeState s) s a}
  deriving (Functor, Applicative, Monad)


instance (Monad s, MonadSTM s, MonadTimer s, Alternative s, MonadFork s)
      => Algebra NodeAction (NodeActionC s) where
  alg hdl sig ctx = NodeActionC $ StateC $ \ns -> case sig of
    SendMessage ni mes -> do
      let (input, output) = fromMaybe (error "never happened") $ Map.lookup ni (ns ^. peers)
      atomically (writeTQueue output mes) >> pure (ns, ctx)
    ReadMessage ni -> do
      let (input, output) = fromMaybe (error "never happened") $ Map.lookup ni (ns ^. peers)
      atomically (readTQueue input) >>= \x -> pure (ns, x <$ ctx)
    DeleteNode ni -> pure (ns & peers %~ Map.delete ni, ctx)
    PeekWithTimeout dt ni -> do
      let (input, output) = fromMaybe (error "never happened") $ Map.lookup ni (ns ^. peers)
      val <- timeout dt $ atomically $ readTQueue input
      pure (ns, val <$ ctx)
    GetNodeId -> pure (ns, ns ^. nodeId <$ ctx)
    GetPeers -> pure (ns, Map.keysSet (ns ^. peers) <$ ctx)
    Wait dt -> threadDelay dt >> pure (ns, ctx)
    PeekSomeMessageFromAllPeersWithTimeout dt nis mes -> do
      let nidSet = Set.fromList nis
          nids = fmap snd
               $ Map.elems
               $ Map.filterWithKey (\k _ -> Set.member k nidSet) (ns ^. peers)
          peekOrRetry tq = do
              val <- peekTQueue tq
              if val == mes
                then pure True
                else retry
      val <- timeout dt $ atomically $ foldr (<|>) retry (fmap peekOrRetry nids)
      pure (ns, val <$ ctx)
    WaitAnyMessageFromAllPeers -> do
      let nids = fmap (second snd) $ Map.toList $ ns ^. peers
      val <- atomically $ foldr (<|>) retry (fmap (\(id, tq) -> (id,) <$> readTQueue tq) nids)
      pure (ns, val <$ ctx)
    ForkPingReqHandler ni' dt ni -> do
      let (input', output') = fromMaybe (error "never happened") $ Map.lookup ni' (ns ^. peers)
          (input, output) = fromMaybe (error "never happened") $ Map.lookup ni (ns ^. peers)
      forkIO $ void $ do
        atomically $ writeTQueue output' Ping
        res <- timeout dt $ atomically $ readTQueue input'
        case res of
          Just Ack -> atomically $ writeTQueue output (Alive ni')
          _        -> pure ()
      pure (ns, ctx)

runNodeAction :: NodeState s -> NodeActionC s a -> s (NodeState s, a)
runNodeAction tq f = runState tq $ runNodeActionC f

