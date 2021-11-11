{-# LANGUAGE FlexibleContexts #-}

module Gossip.Swim.A where
import           Control.Carrier.Random.Gen
import           Control.Effect.Labelled
import           Gossip.NodeAction



data Value = Value

data Message
  = Ping
  | Ack
  | PingReq NodeId
  | Alive NodeId
  | Dead NodeId

failuerDetector :: (HasLabelled NodeAction (NodeAction s Value Message) sig m,
                    Has Random sig m)
                => m ()
failuerDetector = do

  undefined

