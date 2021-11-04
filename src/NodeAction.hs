{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
module NodeAction where

import           Control.Algebra
import           Control.Carrier.Lift
import           Control.Carrier.Random.Gen
import           Control.Carrier.Reader
import           Control.Carrier.State.Strict
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TQueue
import           Control.Effect.Labelled
import           Control.Effect.Optics
import           Control.Effect.Optics.Indexed
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.IORef
import           Data.Kind
import           Data.Map                      (Map)
import qualified Data.Map                      as Map
import           Data.Map.Optics
import           Data.Proxy
import           Data.String                   (IsString)
import           Optics                        (At (at), makeLenses, (%), (%~),
                                                (&), (.~), (?~), (^.))
import           System.Random.Stateful        (mkStdGen, uniform)
-- Map Name (Chan message)
-- sendMessage Name message
-- receiveMessage Name

newtype NodeId = NodeId Int deriving (Show, Eq, Ord)

data NodeAction message (m :: Type -> Type) a where
  SendMessage :: NodeId -> message -> NodeAction message m Bool
  ReceiveMessage :: NodeAction message m (Either String (NodeId, message))
  AddFriend :: NodeId -> TQueue (NodeId, message) -> NodeAction message m ()
  RemoveFriend :: NodeId -> NodeAction message m ()
  GetSelfNodeId :: NodeAction message m NodeId

sendMessage :: HasLabelled NodeAction (NodeAction message) sig m
            => NodeId
            -> message
            -> m Bool
sendMessage nodeId message = sendLabelled @NodeAction $ SendMessage nodeId message

receiveMessage :: HasLabelled NodeAction (NodeAction message) sig m
               => m (Either String (NodeId, message))
receiveMessage = sendLabelled @NodeAction $ ReceiveMessage

addFriend :: HasLabelled NodeAction (NodeAction message) sig m
          => NodeId
          -> TQueue (NodeId, message)
          -> m ()
addFriend nodeId chan = sendLabelled @NodeAction (AddFriend nodeId chan)

removeFriend :: HasLabelled NodeAction (NodeAction message) sig m
             => NodeId
             -> m ()
removeFriend nodeId = sendLabelled @NodeAction (RemoveFriend nodeId)

getSelfNodeId :: HasLabelled NodeAction (NodeAction message) sig m => m NodeId
getSelfNodeId = sendLabelled @NodeAction GetSelfNodeId

-- data Command

data NodeConnState message
  = NodeConnState
  { _friends    :: Map NodeId (TQueue (NodeId, message))
  , _nodeId     :: NodeId
  , _inputQueue :: TQueue (NodeId, message)
  }

makeLenses ''NodeConnState

newtype NodeActionC message m a =
  NodeActionC { runNodeActionC :: StateC (NodeConnState message) m a}
  deriving (Functor, Applicative ,Monad, MonadIO)

instance (Algebra sig m, MonadIO m, Show message) =>
  Algebra (NodeAction message :+: sig) (NodeActionC message m) where
    alg hdl sig ctx = NodeActionC $ StateC $ \nc ->  case sig of
      L (SendMessage nid message) -> case nc ^. friends % at nid of
                                        Nothing -> pure (nc, False <$ ctx)
                                        Just tq -> liftIO (atomically $ writeTQueue tq (nc^.nodeId, message))
                                              >> pure (nc, True <$ ctx)
      L ReceiveMessage            -> liftIO (atomically $ readTQueue (nc ^. inputQueue))
                                               >>= \x -> pure (nc, Right x <$ ctx)
      L (AddFriend nodeId chan)   -> pure (nc & friends % at nodeId ?~ chan , ctx)
      L (RemoveFriend nodeId)     -> pure (nc & friends %~ Map.delete nodeId, ctx)
      L GetSelfNodeId             -> pure (nc, (nc ^. nodeId) <$ ctx)
      R other                     -> thread (uncurry runState ~<~ runNodeActionC . hdl) other (nc, ctx)

runNodeAction :: MonadIO m
              => NodeConnState message
              -> Labelled NodeAction (NodeActionC message) m a
              -> m (NodeConnState message, a)
runNodeAction nc f = runState nc $ runNodeActionC $ runLabelled f

foo :: (Has Random sig m,
        HasLabelled NodeAction (NodeAction String) sig m,
        MonadIO m)
    => NodeId
    -> m ()
foo friendId = do
  lable <- getSelfNodeId
  let go = do
         time <- uniformR (1,10)
         liftIO $ threadDelay (time * 10^5)
         c <- replicateM  18 $ uniformR ('a', 'z')
         sendMessage friendId c
         liftIO $ putStrLn $ "send message "++ c ++ ", from " ++ show lable ++  " to trager: " ++ show friendId
         v <- receiveMessage @String
         liftIO $ putStrLn $ "receive message: " ++ show v ++ ",from source " ++ show friendId ++ " to " ++ show lable
         go
  go

runfoo :: IO ()
runfoo = do
  tq1 <- newTQueueIO
  tq2 <- newTQueueIO
  let n1 = NodeId 1
      n2 = NodeId 2
  forkIO $ void $ runNodeAction @IO @String
                     (NodeConnState (Map.singleton n2 tq2) n1 tq1)
                $ evalRandom (mkStdGen 10)
                $ foo n2

  void $ runNodeAction @IO @String
            (NodeConnState (Map.singleton n1 tq1) n2 tq2)
       $ evalRandom (mkStdGen 11)
       $ foo n1
