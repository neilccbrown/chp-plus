-- Communicating Haskell Processes.
-- Copyright (c) 2008--2009, University of Kent.
-- All rights reserved.
-- 
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are
-- met:
--
--  * Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
--  * Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--  * Neither the name of the University of Kent nor the names of its
--    contributors may be used to endorse or promote products derived from
--    this software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
-- IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
-- CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
-- EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
-- PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
-- PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
-- LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
-- NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-- | This module contains helper functions for wiring up collections of processes
-- into a two-dimensional arrangement.
module Control.Concurrent.CHP.Connect.TwoDim
  (FourWay(..), wrappedGridFour, wrappedGridFour_,
   FourWayDiag(..), EightWay, wrappedGridEight, wrappedGridEight_) where

import Control.Arrow
import Control.Concurrent.CHP
import Control.Concurrent.CHP.Connect
import Control.Monad
import Data.List

import Prelude hiding (abs)

-- | A data type representing four-way connectivity for a process, with channels
-- to the left and right, above and below.
data FourWay above below left right
  = FourWay { above :: above, below :: below, left :: left, right :: right }
    deriving (Eq)

-- | A data type representing four-way diagonal connectivity for a process, with
-- channels above-left, below-right, above-right and below-left.
data FourWayDiag aboveLeft belowRight aboveRight belowLeft
  = FourWayDiag { aboveLeft :: aboveLeft, belowRight :: belowRight, aboveRight :: aboveRight, belowLeft :: belowLeft }
    deriving (Eq)

-- | EightWay is simply a synonym for a pair of 'FourWay' and 'FourWayDiag'.
type EightWay a b l r al br ar bl  = (FourWay a b l r, FourWayDiag al br ar bl)

-- | Wires the given grid of processes (that require four-way connectivity) together
-- into a wrapped around grid (a torus) and runs them all in parallel.
--
-- The parameter is a list of rows, and should be rectangular (i.e. all the rows
-- should be the same length).  If not, an error will result.  The return value
-- is guaranteed to be the same shape as the input.
--
-- It is worth remembering that if you have only one row or one column (or
-- both), processes can be connected to themselves, so make sure that if a
-- process is connected to itself (e.g. its left channel connects to its right
-- channel), it is coded such that it won't deadlock -- or if needed, checks for this
-- possibility using 'sameChannel'.  Processes may also be connected to each other
-- multiple times -- in a two-wide grid, each process's left channel connects to
-- the same process as its right.
wrappedGridFour :: (Connectable above below, Connectable left right) =>
  [[FourWay above below left right -> CHP a]] -> CHP [[a]]
wrappedGridFour ps
  -- If ps == [], this will succeed, and map connectRowCycle ps will be [],
  -- and thus connectColumnsCycle _ [] will return [] (without forcing the
  -- head call), and it will all work correctly.
  | length (nub $ map length ps) <= 1
     = connectColumnsCycle (length (head ps)) $ map connectRowCycle ps
  | otherwise
     = error $ "Control.Concurrent.CHP.Connect.TwoDim.wrappedGrid: Non-rectangular input "
               ++ " height: " ++ show (length ps) ++ " widths: " ++ show (map length ps)

-- | Like 'wrappedGridFour' but discards the return values.
wrappedGridFour_ :: (Connectable above below, Connectable left right) =>
  [[FourWay above below left right -> CHP a]] -> CHP ()
wrappedGridFour_ ps = wrappedGridFour ps >> return () --TODO fix this

-- | Like 'wrappedGridFour' but provides eight-way connectivity.
--
-- The note on 'wrappedGridFour' about processes being connected to themselves
-- applies here too -- as does the note about processes being connected to
-- each other multiple times.  If you have one row, a process's left,
-- above-left and below-left channels all connect to the same process.  If you
-- have a two-by-two grid, a process's four diagonal channels all connect to
-- the same process.
wrappedGridEight :: (Connectable above below, Connectable left right,
              Connectable aboveLeft belowRight, Connectable belowLeft aboveRight) =>
  [[EightWay above below left right aboveLeft belowRight aboveRight belowLeft -> CHP a]] -> CHP [[a]]
wrappedGridEight ps
  | length (nub $ map length ps) <= 1
     = connectColumnsCycleDiag (length (head ps)) $ map connectRowCycleDiag ps
  | otherwise
     = error $ "Control.Concurrent.CHP.Connect.TwoDim.wrappedGridDiag: Non-rectangular input "
               ++ " height: " ++ show (length ps) ++ " widths: " ++ show (map length ps)

-- | Like 'wrappedGridEight' but discards the output.
wrappedGridEight_ :: (Connectable above below, Connectable left right,
              Connectable aboveLeft belowRight, Connectable belowLeft aboveRight) =>
  [[EightWay above below left right aboveLeft belowRight aboveRight belowLeft -> CHP a]] -> CHP ()
wrappedGridEight_ ps = wrappedGridEight ps >> return ()


connectRowCycle :: Connectable left right =>
  [FourWay above below left right -> CHP a] -> ([(above, below)] -> CHP [a])
connectRowCycle [] _ = return []
connectRowCycle allps abs = connect $
  foldr connLR
        -- The last process is special because it must take both channels for itself:
        (liftM (:[]) . last allps . uncurry (uncurry FourWay $ last abs))
        (zip (init allps) (init abs))

connLR :: Connectable left right =>
          (FourWay above below left right -> CHP a, (above, below))
       -> ((left, right) -> CHP [a])
       -> ((left, right) -> CHP [a])
connLR (p, (a, b)) q (l, r)
  = liftM (uncurry (:)) . connect $ \(l', r') -> p (FourWay a b l r') <||> q (l', r)

connectColumnsCycle :: Connectable above below => Int -> [[(above, below)] -> CHP [a]] -> CHP [[a]]
connectColumnsCycle _ [] = return []
connectColumnsCycle n ps = connectList n $ foldl1 (connAB n) (map (liftM (:[]) .) ps)

connAB :: Connectable above below => Int -> ([(above, below)] -> CHP [a]) -> ([(above, below)] -> CHP [a]) -> ([(above, below)] -> CHP [a])
connAB n p q abs = liftM (uncurry (++)) $ connectList n $ \abs' -> p (zip (map fst abs) (map snd abs'))
  <||> q (zip (map fst abs') (map snd abs))

connectColumnsCycleDiag :: (Connectable a b, Connectable bl ar, Connectable al br) =>
  Int -> [[((a, b), FourWayDiag al br ar bl)] -> CHP [z]] -> CHP [[z]]
connectColumnsCycleDiag _ [] = return []
connectColumnsCycleDiag n ps = connectList n $ \abs ->
  connectList n $ \leadingDiag -> connectList n $ \otherDiag ->
    foldl1 (connABDiag n) (map (liftM (:[]) .) ps)
      $ zip abs [FourWayDiag al br ar bl
                | (_, ar) <- otherDiag
                | (bl, _) <- shiftRight otherDiag
                | (al, _) <- leadingDiag
                | (_, br) <- shiftLeft leadingDiag]

-- Let's imagine we have a square:
--
-- A B C
-- D E F
-- G H I
--
-- We pass in the outer-most channels as the processes need them to be wired.
--
-- So for example, A will recieve:
-- aboveLeft: AI
-- aboveRight AH
-- belowLeft: AF
-- belowRight: AE
--
-- So for example when we create the leadingDiag channels:
--
-- \1 \2 \3 
-- A  B  C
--
-- The ends are passed to the above channels as-is, but to the below channels shifted lleft:
--
-- G  H  I
-- \2 \3 \1
--
-- For the otherDiag, shifted right when below:
--
-- /1 /2 /3
-- A  B  C
--
-- G  H  I
-- /3 /1 /2

shiftLeft, shiftRight :: [a] -> [a]
shiftLeft [] = []
shiftLeft xs = tail xs ++ [head xs]
shiftRight [] = []
shiftRight xs = last xs : init xs

connABDiag :: (Connectable above below, Connectable al br, Connectable bl ar) =>
  Int -> ([((above, below), FourWayDiag al br ar bl)] -> CHP [a])
  -> ([((above, below), FourWayDiag al br ar bl)] -> CHP [a])
  -> ([((above, below), FourWayDiag al br ar bl)] -> CHP [a])
connABDiag n p q abs = liftM (uncurry (++)) $ connectList n $ \abs' ->
  connectList n $ \leadingDiag -> connectList n $ \otherDiag ->
    p [((a, b), FourWayDiag al br ar bl)
      | ((a, _), _) <- abs
      | (_, b) <- abs'
      | (_, FourWayDiag al _ ar _) <- abs
      | (bl, _) <- shiftRight otherDiag
      | (_, br) <- shiftLeft leadingDiag
      ]
  <||>
    q [((a, b), FourWayDiag al br ar bl)
      | ((_, b), _) <- abs
      | (a, _) <- abs'
      | (al, _) <- leadingDiag
      | (_, ar) <- otherDiag
      | (_, FourWayDiag _ br _ bl) <- abs
      ]
-- We are given our own above and below as we need them to be arranged already.


connectRowCycleDiag :: Connectable l r =>
  [EightWay a b l r al br ar bl -> CHP z]
  -> ([((a, b), FourWayDiag al br ar bl)] -> CHP [z])
connectRowCycleDiag [] _ = return []
connectRowCycleDiag allps abs = connect $
  foldr connLRDiag
        -- The last process is special because it must take both channels for itself:
        (\lr -> liftM (:[]) $ last allps $ first (($ lr) . uncurry . uncurry FourWay) (last abs))
        (zip (init allps) (init abs))


connLRDiag :: Connectable l r =>
          (EightWay a b l r al br ar bl -> CHP z, ((a, b), FourWayDiag al br ar bl))
       -> ((l, r) -> CHP [z])
       -> ((l, r) -> CHP [z])
connLRDiag (p, ((a, b), diag)) q (l, r)
  = liftM (uncurry (:)) . connect $ \(l', r') -> p (FourWay a b l r', diag) <||> q (l', r)
