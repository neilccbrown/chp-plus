-- Communicating Haskell Processes.
-- Copyright (c) 2009-2010, Neil Brown.
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
--  * Neither the name of the Neil Brown nor the names of other
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

-- | A module containing a 'Composed' monad.
--
-- The 'Composed' monad can be thought of as an equivalent to functions elsewhere
-- in chp-plus (especially the "Control.Concurrent.CHP.Connect" module) that support
-- partial application of processes when wiring them up.
--
-- Binding in this monad can be thought of as \"and then wire that like this\".
--  You compose your processes together with a series of monadic actions, feeding
-- processes into each function that wires up the next parameter, then taking the
-- results of that action and further wiring it up another way.  At the end of
-- the monadic block you should return the full list of wired-up processes, to
-- be run in parallel using the 'run' (or 'run_') functions.
--
-- Here is a simple example.  You have a list of processes that take an incoming
-- and outgoing channel end and a barrier, and you want to wire them into a cycle
-- and enroll them all on the barrier:
--
-- > processes :: [Chanin a -> Chanout a -> EnrolledBarrier -> CHP ()]
-- >
-- > runProcesses = do b <- newBarrier
-- >                   run $ cycleR processes >>= enrollAllR b
--
-- The order of the actions in this monad tends not to matter (it is a commutative
-- monad for the most part) so you could equally have written:
--
-- > processes :: [EnrolledBarrier -> Chanin a -> Chanout a -> CHP ()]
-- >
-- > runProcesses = do b <- newBarrier
-- >                   run $ enrollAllR b processes >>= cycleR
--
-- Remember with this monad to return all the processes to be run in parallel;
-- if they are not returned, they will not be run and you will likely get deadlock.
--
-- A little more background on the monad is available in this blog post: <http://chplib.wordpress.com/2010/01/19/the-process-composition-monad/>
module Control.Concurrent.CHP.Composed
  (Composed, runWith, run, run_, enrollR, enrollAllR, connectR, pipelineR, pipelineCompleteR, cycleR,
    wrappedGridFourR)
    where

import Control.Applicative
import Control.Concurrent.CHP
import Control.Concurrent.CHP.Connect
import Control.Concurrent.CHP.Connect.TwoDim (FourWay(..))
import Control.Monad
import Data.List (transpose)

-- | A monad for composing together CHP processes in cross-cutting ways; e.g. wiring
-- together a list of processes into a pipeline, but also enrolling them all on
-- a barrier.
newtype Composed a = Composed {
  runWith :: forall b. (a -> CHP b) -> CHP b
  -- ^ See 'run' and 'run_'
  }

instance Monad Composed where
  return x = Composed ($ x)
  (>>=) m f = Composed (\r -> m `runWith` ((`runWith` r) . f))

instance MonadCHP Composed where
  liftCHP x = Composed (x >>=)

instance Functor Composed where
  fmap = liftM

instance Applicative Composed where
  pure = return
  (<*>) = ap

-- | Given a list of CHP processes composed using the Composed monad, runs them
-- as a parallel bunch of CHP results (with 'runParallel') and returns the results.
run :: Composed [CHP a] -> CHP [a]
run p = p `runWith` runParallel

-- | Like 'run' but discards the results (uses 'runParallel_').
run_ :: Composed [CHP a] -> CHP ()
run_ p = p `runWith` runParallel_

-- | Like 'enroll', this takes a barrier and a process wanting a barrier, and enrolls
-- it for the duration, but operates using the 'Composed' monad.
enrollR :: Enrollable b p => b p -> (Enrolled b p -> a) -> Composed a
enrollR b p = Composed (\r -> enroll b (r . p))

-- | Given an 'Enrollable' item (such as a 'Barrier'), and a list of processes,
-- composes them by enrolling them all on the given barrier.
enrollAllR :: Enrollable b p => b p -> [Enrolled b p -> a] -> Composed [a]
enrollAllR b ps = Composed (\r -> enrollAllT r (return b) ps)

-- | Like 'connect' but operates in the 'Composed' monad.
connectR :: Connectable l r => ((l, r) -> a) -> Composed a
connectR p = Composed (\r -> connect (r . p))

-- | Wires a list of processes into a pipeline that takes the two channels for
-- the ends of the pipeline and returns the list of wired-up processes.
pipelineR :: Connectable l r => [r -> l -> a] -> Composed (r -> l -> [a])
pipelineR [] = return $ const $ const []
pipelineR (first:rest) = foldM pcr (\x y -> [first x y]) rest
  where
    pcr p q = connectR $ \(l, r) x y -> (p x l) ++ [q r y]

-- Similar to 'pipelineR' but puts a process at the beginning and end of the pipeline.
--  The list is returned in the order @[start] ++ middle ++ [end]@.
pipelineCompleteR :: Connectable l r => (l -> a) -> [r -> l -> a] -> (r -> a) -> Composed [a]
pipelineCompleteR start middle end
  = do midWired <- pipelineR middle
       startAndMiddle <- connectR $ \(l, r) e -> start l : midWired r e
       connectR $ \(l, r) -> startAndMiddle l ++ [end r]

-- | Connects together a list of processes into a cycle.
cycleR :: Connectable l r => [r -> l -> a] -> Composed [a]
cycleR [] = return []
cycleR [p] = (:[]) <$> connectR (uncurry $ flip p)
cycleR ps = pipelineR ps >>= connectR . uncurry . flip

-- | Like 'wrappedGridFour', but in the 'Composed' monad.
wrappedGridFourR :: (Connectable below above, Connectable right left) =>
  [[FourWay above below left right -> a]] -> Composed [[a]]
wrappedGridFourR = (return . transpose) <=< mapM cycleR <=< (return . transpose) <=< mapM (connectRowR)
  where
--    connectRowR :: [FourWay above below left right -> a] -> [below -> above -> a]
    connectRowR ps = cycleR [\l r a b -> p (FourWay a b l r) | p <- ps]

--wrappedGridFourR' :: (Connectable below above, Connectable right left) =>
--  [[above -> below -> left -> right -> a]] -> Composed [[a]]
--wrappedGridFourR' = (mapM cycleConnectR . transpose) <=< (mapM cycleConnectR . transpose)
--  where
--    connectRowR :: [FourWay above below left right -> a] -> [below -> above -> a]
--    connectRowR ps = cycleConnectR [\l r a b -> p (FourWay a b l r) | p <- ps]
