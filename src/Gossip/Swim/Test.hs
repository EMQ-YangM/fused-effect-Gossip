{-# LANGUAGE AllowAmbiguousTypes #-}

module Gossip.Swim.Test where

import           Gossip.Swim.A
import           Gossip.Swim.Impl
import           Gossip.Swim.Type

import           Control.Effect.IOClasses (Algebra, DiffTime, IOSim,
                                           MonadDelay (threadDelay),
                                           MonadFork (forkIO),
                                           MonadST (withLiftST),
                                           MonadSTM (STM, atomically, newTQueueIO, readTVarIO),
                                           MonadSTMTx (TQueue_, TVar_, peekTQueue, readTQueue, readTVar, retry, writeTBQueue, writeTQueue, writeTVar),
                                           MonadSay (say),
                                           MonadTime (getCurrentTime),
                                           MonadTimer (timeout), SimTrace,
                                           runSimTraceST, selectTraceEventsSay)


mkDTQ :: (Monad s,
          MonadSTM s,
          MonadTimer s,
          MonadFork s)
      => s (TQueue_ (STM s) Message, TQueue_ (STM s) Message)
mkDTQ = do
  readTQ <- newTQueueIO
  writeTQ <- newTQueueIO
  pure (readTQ, writeTQ)


mkDTQEffect :: (Monad s,
          MonadSTM s,
          MonadTimer s,
          MonadFork s)
      => (Message -> s ())
      -> (Message -> s ())
      -> s (TQueue_ (STM s) Message, TQueue_ (STM s) Message)
mkDTQEffect beforeSend afterRecv = do
  readTQ <- newTQueueIO
  writeTQ <- newTQueueIO
  pure (readTQ, writeTQ)











