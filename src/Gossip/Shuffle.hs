{-# LANGUAGE FlexibleContexts #-}
module Gossip.Shuffle where


import           Control.Monad.ST
import           Data.Set               (Set)
import qualified Data.Set               as Set
import           Data.Vector            (Vector, unsafeFreeze, (!))
import           Data.Vector.Mutable
import           System.Random.Stateful

shuffle :: Int -> STGenM StdGen s -> ST s (Vector Int)
shuffle n gen = do
  vec <- generate n id
  let lst = n -1
      loop i | i == lst  = pure ()
             | otherwise = do
                 j <- uniformRM (i, lst) gen
                 unsafeSwap vec i j
                 loop (i + 1)
  loop 0
  unsafeFreeze vec

shuffleVec :: Int -> StdGen -> Vector Int
shuffleVec n gen = fst $ runSTGen gen (shuffle n)

shuffleSet :: StdGen -> Set s -> [s]
shuffleSet gen set =
  let n = Set.size set
      svec = shuffleVec n gen
  in map (\i -> Set.elemAt (svec ! i) set) [0 .. n - 1]
