-- Communicating Haskell Processes.
-- Copyright (c) 2009, University of Kent.
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


-- | A module containing CHP behaviours.  See 'offer' for details.
module Control.Concurrent.CHP.Behaviours (
  CHPBehaviour, offer, offerAll, alongside, alongside_, endWhen, once, upTo, repeatedly, repeatedly_,
  repeatedlyRecurse, repeatedlyRecurse_) where

import Control.Applicative
import Control.Monad

import Control.Concurrent.CHP

-- | This data represents a behaviour (potentially repeated) that will result in
-- returning a value of type @a@.  See 'offer' for more details.
data CHPBehaviour a = CHPBehaviour a (Maybe (CHP (CHPBehaviour a)))

instance Functor CHPBehaviour where
  fmap f (CHPBehaviour x Nothing) = CHPBehaviour (f x) Nothing
  fmap f (CHPBehaviour x (Just m)) = CHPBehaviour (f x) (Just $ fmap f <$> m)

-- | Offers the given behaviour, and when it occurs, ends the entire call to 'offer'.
--  Returns Just the result if the behaviour happens, otherwise gives Nothing.
endWhen :: CHP a -> CHPBehaviour (Maybe a)
endWhen m = CHPBehaviour Nothing (Just $ (\x -> CHPBehaviour (Just x) Nothing) <$> m)

-- | Offers the given behaviour, and when it occurs, does not offer it again.
-- Returns Just the result if the behaviour happens, otherwise gives Nothing.
-- 'once' is different to 'endWhen' because the latter terminates the call to 'offer'
-- regardless of other behaviours, whereas 'once' does not terminate the call to 'offer',
-- it just won't be offered again during the call to 'offer'.  Thus if you only
-- offer some 'once' items without any 'endWhen', then after all the 'once' events
-- have happened, the process will deadlock.
--
-- @once m@ can be thought of as a shortcut for @listToMaybe <$> upTo1 m@
once :: CHP a -> CHPBehaviour (Maybe a)
once m = CHPBehaviour Nothing (Just $ (\x -> CHPBehaviour (Just x) (Just stop)) <$> m)


-- | Offers the given behaviour up to the given number of times, returning a list
-- of the results (in chronological order).  Like 'once', when the limit is reached,
-- the call to 'offer' is not terminated, so you still require an 'endWhen'.
upTo :: Int -> CHP a -> CHPBehaviour [a]
upTo n m = reverse <$> upTo' []
  where
    upTo' xs
      = CHPBehaviour xs $ Just $ if length xs >= n then stop else (upTo' . (:xs)) <$> m

-- | Repeatedly offers the given behaviour until the outer call to 'offer' is terminated
-- by an 'endWhen' event.  A list is returned (in chronological order) of the results
-- of each occurrence of the behaviour.  @repeatedly@ is like an unbounded @upTo@.
repeatedly :: forall a. CHP a -> CHPBehaviour [a]
repeatedly m = reverse <$> repeatedly' []
  where
    repeatedly' :: [a] -> CHPBehaviour [a]
    repeatedly' xs = CHPBehaviour xs $ Just $ (repeatedly' . (:xs)) <$> m

-- | Like 'repeatedly', but discards the output.  Useful if the event is likely
-- to occur a lot, and you don't need the results.
repeatedly_ :: CHP a -> CHPBehaviour ()
repeatedly_ m = CHPBehaviour () $ Just $ m >> return (repeatedly_ m)

-- | Like 'repeatedly', but allows some state (of type @a@) to be passed from one
-- subsequent call to another, as well as generating the results of type @b@.
-- To begin with the function (first parameter) will be called with the initial
-- state (second parameter).  If chosen, it will return the new state, and a result
-- to be accumulated into the list.  The second call to the function will be passed
-- the new state, to then return the even newer state and a second result, and
-- so on.
--
-- If you want to use this with the StateT monad transformer from the mtl library,
-- you can call:
--
-- > repeatedlyRecurse (runStateT myStateAction) initialState
-- >   where
-- >     myStateAction :: StateT s CHP a
-- >     initialState :: s
repeatedlyRecurse :: forall a b. (a -> CHP (b, a)) -> a -> CHPBehaviour [b]
repeatedlyRecurse f = fmap reverse . repeatedlyRecurse' []
  where
    repeatedlyRecurse' :: [b] -> a -> CHPBehaviour [b]
    repeatedlyRecurse' rs x = CHPBehaviour rs $ Just $
      (\(r, y) -> repeatedlyRecurse' (r : rs) y) <$> f x

-- | Like 'repeatedlyRecurse', but does not accumulate a list of results.
--
-- If you want to use this with the StateT monad transformer from the mtl library,
-- you can call:
--
-- > repeatedlyRecurse (execStateT myStateAction) initialState
-- >   where
-- >     myStateAction :: StateT s CHP a
-- >     initialState :: s
repeatedlyRecurse_ :: forall a. (a -> CHP a) -> a -> CHPBehaviour ()
repeatedlyRecurse_ f = repeatedlyRecurse'
  where
    repeatedlyRecurse' :: a -> CHPBehaviour ()
    repeatedlyRecurse' x = CHPBehaviour () $ Just $ repeatedlyRecurse' <$> f x

-- | Offers one behaviour alongside another, combining their semantics.  See 'offer'.
--
-- This operation is semantically associative and commutative.
alongside :: CHPBehaviour a -> CHPBehaviour b -> CHPBehaviour (a, b)
alongside oa@(CHPBehaviour a mfa) ob@(CHPBehaviour b mfb)
  = CHPBehaviour (a, b) (do fa <- mfa
                            fb <- mfb
                            return $ (flip alongside ob <$> fa) <-> (alongside oa <$> fb)
                        )

-- | Offers one behaviour alongside another, combining their semantics.  See 'offer'.
-- Unlike 'alongside', discards the output of the behaviours.
--
-- This operation is associative and commutative.
alongside_ :: CHPBehaviour a -> CHPBehaviour b -> CHPBehaviour ()
alongside_ (CHPBehaviour _ mfa) (CHPBehaviour _ mfb)
  = CHPBehaviour () (liftM2 (<->) (liftM blank <$> mfa) (liftM blank <$> mfb))
  where
    blank :: CHPBehaviour c -> CHPBehaviour ()
    blank = fmap (const ())

infixr `alongside`

-- | Offers the given behaviour until finished.
--
-- For example,
-- 
-- > offer $ repeatedly p `alongside` repeatedly q
-- 
-- will repeatedly offer p and q without ever terminating.  This:
-- 
-- > offer $ repeatedly p `alongside` repeatedly q `alongside` endWhen r
-- 
-- will offer p repeatedly and q repeatedly and r, until r happens, at which point
-- the behaviour will end.
-- This:
-- 
-- > offer $ once p `alongside` endWhen q
-- 
-- will offer p and q; if p happens first it will wait for q, but if q happens
-- first it will finish.  This:
-- 
-- > offer $ once p `alongside` endWhen q `alongside` endWhen r
-- 
-- permits p to happen at most once, while either of q or r happening will finish
-- the call.
--
-- All sorts of combinations are possible, but it is important to note that you
-- need at least one 'endWhen' event if you ever intend the call to finish.  Some
-- laws involving 'offer' (ignoring the types and return values) are:
--
-- > offer (repeatedly p) == forever p
-- > offer (once p) == p >> stop -- i.e. it does not finish
-- > offer (endWhen q) == Just <$> q
-- > offer (endWhen p `alongside` endWhen q) == p <-> q
-- > offer (once p `alongside` endWhen q) == (p >> q) <-> q
--
-- Most other uses of 'offer' and 'alongside' do not reduce down to simple CHP
-- programs, which is of course their attraction.
offer :: CHPBehaviour a -> CHP a
offer (CHPBehaviour x Nothing) = return x
offer (CHPBehaviour _x (Just m)) = m >>= offer

-- | Offers all the given behaviours together, and gives back a list of the outcomes.
--  
-- This is roughly a shorthand for @offer . foldl1 alongside@, except that if you
-- pass the empty list, you simply get the empty list returned (rather than an
-- error)
offerAll :: [CHPBehaviour a] -> CHP [a]
offerAll [] = return []
offerAll bs = offer $ foldl1 (\x y -> fmap (uncurry (++)) $ alongside x y) bs'
  where
    bs' = map (fmap (:[])) bs
