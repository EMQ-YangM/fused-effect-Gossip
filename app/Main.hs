module Main where

import Gossip.SIR.BlindCoin

main :: IO ()
main = do
  putStrLn "Hello, Haskell!"
  runSim
  -- write
  return ()

