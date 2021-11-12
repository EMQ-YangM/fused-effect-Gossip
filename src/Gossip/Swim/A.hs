{-# LANGUAGE AllowAmbiguousTypes        #-}
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
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

module Gossip.Swim.A where
import           Control.Algebra              hiding (send)
import           Control.Carrier.Lift
import           Control.Carrier.Random.Gen
import           Control.Carrier.State.Strict
import           Control.Effect.Labelled      hiding (send)
import           Control.Monad
import           Data.Kind
import qualified Data.List                    as L
import qualified Data.Map                     as Map
import qualified Data.Set                     as Set
import           Gossip.Shuffle
import           Gossip.Swim.Type
import           System.Random                (mkStdGen)


broadcast :: (Has (Random :+: NodeAction) sig m)
          => Int
          -> Message
          -> m [NodeId]
broadcast n message = do
  peers <- getPeers
  gen <- mkStdGen <$> uniform
  let shuffle = shuffleSet gen peers
  forM (take n shuffle) $ \id -> do
    sendMessage id message
    pure id

loop :: (Has (Random :+: NodeAction) sig m)
     => m ()
loop = do
  peers <- getPeers

  let size = Set.size peers

  i <- uniformR (0, size-1)

  let nid = Set.elemAt i peers

  sendMessage nid Ping

  message <- peekWithTimeout 1 nid

  case message of
    Just v -> case v of
      Ack -> pure ()
      _   -> error "never happened"
    Nothing  -> do
      nids <- broadcast 5 (PingReq nid)
      res <- peekSomeMessageFromAllPeersWithTimeout 2 nids (Alive nid)
      case res of
        Just True -> pure ()
        _         -> do
          deleteNode nid
          broadcast 5 (Dead nid)
          pure ()
  wait 1
  loop

receive :: (Has (Random :+: NodeAction) sig m)
        => m ()
receive = do
  (nid, message) <- waitAnyMessageFromAllPeers
  case message of
    Ping         -> sendMessage nid Ack
    Ack          -> pure ()
    PingReq nid' -> forkPingReqHandler nid' 1 nid
    Alive nid'   -> pure ()
    Dead nid'    -> do
      deleteNode nid'
      broadcast 5 (Dead nid')
      pure ()

  receive
