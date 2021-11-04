{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
module MyLib  where

import           Control.Algebra
import           Control.Carrier.Lift
import           Control.Carrier.Reader
import           Control.Carrier.State.Strict
import           Control.Effect.IOClasses
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Kind

data NodeAction message (m :: Type -> Type) a where
  SendMessage :: message -> NodeAction message m ()
  ReadMessage :: NodeAction message m message

sendMessage :: Has (NodeAction message) sig m => message -> m ()
sendMessage = send . SendMessage

readMessage :: Has (NodeAction message) sig m => m message
readMessage = send ReadMessage

newtype NodeActionC s message m a =
  NodeActionC { runNodeActionC :: (ReaderC (TQueue_ (STM s) message) m) a}
  deriving (Functor, Applicative ,Monad, MonadIO)

instance (Functor s,
          MonadSTM s,
          MonadSay s,
          MonadDelay s,
          MonadTime s,
          Show message,
          Has (Lift s) sig m)
       => Algebra
           (NodeAction message :+: sig)
           (NodeActionC s message m) where
  alg hdl sig ctx = NodeActionC $ case sig of
    L (SendMessage s) -> ReaderC $ \tq -> do
      sendM @s $ do
          threadDelay 1
          t <- getCurrentTime
          say (show s)
          say (show t)
          atomically $ writeTQueue tq s
          say "sendSuccess"
      pure ctx
    L ReadMessage -> ReaderC $ \tq -> do
      v <- sendM @s $ do
          v <- atomically $ readTQueue tq
          say ("read message " ++ show v)
          return v
      pure (v <$ ctx)
    R other -> alg (runNodeActionC . hdl) (R other) ctx

runNodeAction :: TQueue_ (STM s) message -> NodeActionC s message m a -> m a
runNodeAction tq f = runReader tq $ runNodeActionC f

foo :: Has (NodeAction String :+: State Int) sig m => m String
foo = do
  put @Int 1000
  v <- get @Int
  sendMessage (show v)
  sendMessage "nice"
  readMessage @String

runFoo :: IO (Int, String)
runFoo = do
  tq <- newTQueueIO
  runNodeAction @IO @String tq $ runState @Int 0 foo

runFoo1 :: forall s. ST s (SimTrace (Int, String))
runFoo1 = runSimTraceST $ do
  tq <- newTQueueIO
  runNodeAction @(IOSim s) @String tq $ runState @Int 0 foo

runFoo2 = selectTraceEventsSay $ runST runFoo1
