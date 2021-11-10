{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

module Gossip.NodeAction where

import           Codec.CBOR.Decoding          (Decoder)
import qualified Codec.CBOR.Decoding          as CBOR hiding (Done, Fail)
import qualified Codec.CBOR.Encoding          as CBOR
import qualified Codec.CBOR.Read              as CBOR
import           Codec.Serialise
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
                                               MonadSTMTx (TQueue_, TVar_, readTQueue, readTVar, writeTQueue, writeTVar),
                                               MonadSay (say),
                                               MonadTime (getCurrentTime),
                                               SimTrace, runSimTraceST,
                                               selectTraceEventsSay)
import           Control.Effect.Labelled      hiding (send)
import           Control.Effect.Sum           as S
import           Control.Monad
import           Control.Monad.ST
import           Data.ByteString
import qualified Data.ByteString              as BS
import qualified Data.ByteString.Lazy         as LBS
import           Data.Kind
import qualified Data.List                    as L
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import           Data.Set                     (Set)
import qualified Data.Set                     as Set
import           Data.Vector                  ((!))
import qualified Data.Vector                  as V
import           Gossip.Shuffle
import           Optics
import           System.Random                (mkStdGen)


newtype NodeId = NodeId Int deriving (Show, Read, Eq, Ord)

data SIR = I | R | S deriving (Eq, Ord, Show, Read)

data Message = M0 Int
             | M1 Double

data Channel m = Channel {

    -- | Write bytes to the channel.
    --
    -- It maybe raise exceptions.
    --
    send :: LBS.ByteString -> m (),

    -- | Read some input from the channel, or @Nothing@ to indicate EOF.
    --
    -- Note that having received EOF it is still possible to send.
    -- The EOF condition is however monotonic.
    --
    -- It may raise exceptions (as appropriate for the monad and kind of
    -- channel).
    --
    recv :: m (Maybe LBS.ByteString)
  }


instance Serialise Message where
  encode (M0 i) = CBOR.encodeListLen 2 <> CBOR.encodeWord 0 <> CBOR.encodeInt i
  encode (M1 d) = CBOR.encodeListLen 2 <> CBOR.encodeWord 1 <> CBOR.encodeDouble d
  decode = do
    len <- CBOR.decodeListLen
    tag <- CBOR.decodeWord
    case (len, tag) of
      (2, 0) -> M0 <$> decode
      (2, 1) -> M1 <$> decode
      _      -> fail $ "decode Message: unknow tag " ++ show tag

decodeLs :: forall s m a.
            MonadST m
         => (forall b. ST s b -> m b)
         -> Channel m
         -> Maybe LBS.ByteString
         -> Decoder s a
         -> m (Either CBOR.DeserialiseFailure (a, Maybe LBS.ByteString))
decodeLs liftST Channel{recv} trailing decoder =
    liftST (CBOR.deserialiseIncremental decoder) >>= go (LBS.toStrict <$> trailing)
  where
    go :: Maybe BS.ByteString
       -> CBOR.IDecode s a
       -> m (Either CBOR.DeserialiseFailure (a, Maybe LBS.ByteString))
    go Nothing (CBOR.Partial k) =
      recv >>= liftST . k . fmap LBS.toStrict >>= go Nothing
    go (Just bs) (CBOR.Partial k) =
      liftST (k (Just bs)) >>= go Nothing
    go _ (CBOR.Done trailing' _ a) | BS.null trailing'
                                   = return (Right (a, Nothing))
                                   | otherwise
                                   = return (Right (a, Just $ LBS.fromStrict trailing'))
    go _ (CBOR.Fail _ _ failure) = return $ Left failure

echoServer :: forall m a.
              MonadST m
           => Channel m
           -> m (a, Maybe LBS.ByteString)
echoServer channel@Channel {send} = go Nothing
  where
    go :: Maybe LBS.ByteString
       -> m (a, Maybe LBS.ByteString)
    go trailing = do
      res <- withLiftST $ \liftST -> decodeLs liftST channel trailing (decode @Message)
      case res of
        Left err -> do
          error $ "runServer: deserialise error " ++ show err
        Right (msg, trailing') -> do
          send $ serialise msg
          go trailing'

data NodeState s value message
  = NodeState
  { _nodeId     :: NodeId
  , _inputQueue :: TQueue_ (STM s) (NodeId, message)
  , _peers      :: Map NodeId (TQueue_ (STM s) (NodeId, message))
  , _sirState   :: TVar_ (STM s) SIR
  , _store      :: TVar_ (STM s) value
  , _counter    :: TVar_ (STM s) Int
  }

makeLenses ''NodeState

data NodeAction value message (m :: Type -> Type) a where
  SendMessage :: NodeId -> message -> NodeAction value message m ()
  ReadMessage :: NodeAction value message m (NodeId, message)
  GetNodeId   :: NodeAction value message m NodeId
  GetPeers    :: NodeAction value message m (Set NodeId)
  Wait        :: DiffTime -> NodeAction value message m ()
  GetSIRState :: NodeAction value message m SIR
  PutSIRState :: SIR -> NodeAction value message m ()
  ReadStore   :: NodeAction value message m value
  UpdateStore :: value -> NodeAction value message m ()
  GetCounter  :: NodeAction value message m Int
  PutCounter  :: Int -> NodeAction value message m ()

sendMessage :: HasLabelled NodeAction (NodeAction value message) sig m => NodeId -> message -> m ()
sendMessage nid message = sendLabelled @NodeAction (SendMessage nid message)

readMessage :: HasLabelled NodeAction (NodeAction value message) sig m => m (NodeId, message)
readMessage = sendLabelled @NodeAction ReadMessage

getNodeId :: HasLabelled NodeAction (NodeAction value message) sig m => m NodeId
getNodeId = sendLabelled @NodeAction GetNodeId

getPeers :: HasLabelled NodeAction (NodeAction value message) sig m => m (Set NodeId)
getPeers = sendLabelled @NodeAction GetPeers

wait :: HasLabelled NodeAction (NodeAction value message) sig m => DiffTime -> m ()
wait df = sendLabelled @NodeAction (Wait df)

getSIRState :: HasLabelled NodeAction (NodeAction value message) sig m => m SIR
getSIRState = sendLabelled @NodeAction GetSIRState

putSIRState :: HasLabelled NodeAction (NodeAction value message) sig m => SIR -> m ()
putSIRState sir = sendLabelled @NodeAction (PutSIRState sir)

readStore :: HasLabelled NodeAction (NodeAction value message) sig m => m value
readStore = sendLabelled @NodeAction ReadStore

updateStore :: HasLabelled NodeAction (NodeAction value message) sig m => value -> m ()
updateStore message = sendLabelled @NodeAction (UpdateStore message)

getCounter :: HasLabelled NodeAction (NodeAction value message) sig m => m Int
getCounter = sendLabelled @NodeAction GetCounter


putCounter :: HasLabelled NodeAction (NodeAction value message) sig m => Int -> m ()
putCounter i = sendLabelled @NodeAction (PutCounter i)

newtype NodeActionC s value message m a =
  NodeActionC { runNodeActionC :: (StateC (NodeState s value message) m) a}
  deriving (Functor, Applicative ,Monad)

instance (Has (Lift s) sig m,
          MonadDelay s,
          MonadSay s,
          Show message,
          MonadTime s,
          MonadSTM s)
      => Algebra (NodeAction value message :+: sig)
                 (NodeActionC s value message m) where
  alg hdl sig ctx = NodeActionC $ StateC $ \ns -> case sig of
    L (SendMessage nid message) -> do
      case ns ^. peers % at nid of
        Nothing -> undefined
        Just tq -> do
          sendM @s $ do
            time <- getCurrentTime
            say $ show (time, ns ^. nodeId, nid, message)
            -- say $ show time
            --   ++ " send message: "
            --   ++ show message
            --   ++ ". " ++ show (ns ^. nodeId)
            --   ++ "* -> " ++ show nid
            atomically $ writeTQueue tq (ns ^. nodeId, message)
          pure (ns, ctx)
    L ReadMessage  -> do
      res <- sendM @s $  do
        res@(nid, message) <- atomically $ readTQueue (ns ^. inputQueue)
        -- say $ "read message: "
        --   ++ show message
        --   ++ ". " ++ show nid
        --   ++ " -> " ++ show (ns ^. nodeId) ++ "*"
        return res
      pure (ns, res <$ ctx)
    L GetNodeId -> pure (ns, ns ^. nodeId <$ ctx)
    L GetPeers -> pure (ns, Map.keysSet (ns ^. peers) <$ ctx)
    L (Wait df) -> sendM @s (threadDelay df) >> pure (ns, ctx)
    L GetSIRState -> sendM @s (readTVarIO (ns ^. sirState)) >>= \x -> pure (ns, x <$ ctx)
    L (PutSIRState sir) -> sendM @s (atomically $ writeTVar (ns ^. sirState) sir) >> pure (ns, ctx)
    L ReadStore ->  sendM @s (readTVarIO (ns ^. store)) >>= \res -> pure (ns, res <$ ctx)
    L (UpdateStore message) -> sendM @s (atomically $ writeTVar (ns ^. store) message) >> pure (ns, ctx)
    L GetCounter ->  sendM @s (readTVarIO (ns ^. counter)) >>= \res -> pure (ns, res <$ ctx)
    L (PutCounter message) -> sendM @s (atomically $ writeTVar (ns ^. counter) message) >> pure (ns, ctx)
    S.R other  -> thread (uncurry runState . second runNodeActionC ~<~ hdl) other (ns,ctx)


runNodeAction :: NodeState s value message
              -> Labelled NodeAction (NodeActionC s value message) m a
              -> m (NodeState s value message, a)
runNodeAction tq f = runState tq $ runNodeActionC $ runLabelled f
