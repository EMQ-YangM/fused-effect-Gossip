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
module Gossip.Network where

import           Codec.CBOR.Decoding           (Decoder)
import qualified Codec.CBOR.Decoding           as CBOR hiding (Done, Fail)
import qualified Codec.CBOR.Encoding           as CBOR
import qualified Codec.CBOR.Read               as CBOR
import           Codec.Serialise
import           Control.Effect.IOClasses      (Algebra, DiffTime, IOSim,
                                                MonadDelay (threadDelay),
                                                MonadFork (forkIO),
                                                MonadST (withLiftST),
                                                MonadSTM (STM, atomically, newTQueueIO, readTVarIO),
                                                MonadSTMTx (TQueue_, TVar_, readTQueue, readTVar, writeTQueue, writeTVar),
                                                MonadSay (say),
                                                MonadTime (getCurrentTime),
                                                SimTrace, runSimTraceST,
                                                selectTraceEventsSay)
import           Control.Exception.Base        (finally)
import           Control.Monad
import           Control.Monad.ST
import           Control.Tracer                (Contravariant (contramap),
                                                Tracer (..), nullTracer,
                                                stdoutTracer, traceWith)
import qualified Data.ByteString               as BS
import qualified Data.ByteString.Lazy          as LBS
import qualified Data.ByteString.Lazy.Internal as LBS (smallChunkSize)
import           Gossip.NodeAction             (sendMessage)
import           Network.Socket                (Family (AF_UNIX), SockAddr (..))
import qualified Network.Socket                as Socket
import qualified Network.Socket.ByteString     as Socket
import           System.Directory

data Message = M0 Int
             | M1 Double
             deriving (Show)

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

t1 = deserialise @Message $ serialise (M1 10.2)

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


clientWork :: forall m a.
              MonadST m
           => Tracer m String
           -> Message
           -> Channel m
           -> m (Message, Maybe LBS.ByteString)
clientWork tracer msg channel@Channel {send} = go Nothing
  where
    go :: Maybe LBS.ByteString
       -> m (Message, Maybe LBS.ByteString)
    go trailing = do
      send $ serialise msg
      traceWith tracer ("sendMessage: " ++ show msg)
      res <- withLiftST $ \liftST -> decodeLs liftST channel trailing (decode @Message)
      case res of
        Left err -> do
          error $ "runServer: deserialise error " ++ show err
        Right (msg, trailing') -> do
          send $ serialise msg
          pure (msg, trailing')

echoServer :: forall m a.
              MonadST m
           => Tracer m String
           -> Channel m
           -> m (a, Maybe LBS.ByteString)
echoServer tracer channel@Channel {send} = go Nothing
  where
    go :: Maybe LBS.ByteString
       -> m (a, Maybe LBS.ByteString)
    go trailing = do
      res <- withLiftST $ \liftST -> decodeLs liftST channel trailing (decode @Message)
      case res of
        Left err -> do
          error $ "runServer: deserialise error " ++ show err
        Right (msg, trailing') -> do
          traceWith tracer ("receive: " ++ show msg)

          send $ serialise msg
          go trailing'

pipeName = "./demo.sock"

serverWorker sock = do
  let sc = socketAsChannel sock
  echoServer stdoutTracer  sc
  return ()

socketAsChannel :: Socket.Socket -> Channel IO
socketAsChannel socket =
    Channel{send, recv}
  where
    send :: LBS.ByteString -> IO ()
    send chunks =
     -- Use vectored writes.
     Socket.sendMany socket (LBS.toChunks chunks)
     -- TODO: limit write sizes, or break them into multiple sends.

    recv :: IO (Maybe LBS.ByteString)
    recv = do
      -- We rely on the behaviour of stream sockets that a zero length chunk
      -- indicates EOF.
      chunk <- Socket.recv socket LBS.smallChunkSize
      if BS.null chunk
        then return Nothing
        else return (Just (LBS.fromStrict chunk))

client :: IO ()
client = do
    sock <- Socket.socket AF_UNIX Socket.Stream Socket.defaultProtocol
    Socket.connect sock (SockAddrUnix pipeName)
    -- let bearer = socketAsMuxBearer 1.0 nullTracer sock
    -- clientWorker bearer n msg
    let sc = socketAsChannel sock
    r <-  clientWork stdoutTracer (M0 1000) sc
    print r


server :: IO ()
server = do
    sock <- Socket.socket AF_UNIX Socket.Stream Socket.defaultProtocol
    removeFile pipeName
    Socket.bind sock (SockAddrUnix pipeName)
    Socket.listen sock 1
    forever $ do
      (sock', _addr) <- Socket.accept sock
      void $ forkIO $
        serverWorker sock'
          `finally` Socket.close sock'








