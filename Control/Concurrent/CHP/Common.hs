-- Communicating Haskell Processes.
-- Copyright (c) 2008, University of Kent.
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

-- | A collection of useful common processes that are useful when plumbing
-- together a process network.  All the processes here rethrow poison when
-- it is encountered, as this gives the user maximum flexibility (they can
-- let it propagate it, or ignore it).
--
-- The names here overlap with standard Prelude names.  This is
-- deliberate, as the processes act in a similar manner to the
-- corresponding Prelude versions.  It is expected that you will do
-- something like:
--
-- > import qualified Control.Concurrent.CHP.Common as Common
--
-- or:
--
-- > import qualified Control.Concurrent.CHP.Common as CHP
--
-- to circumvent this problem.
module Control.Concurrent.CHP.Common where

import Control.DeepSeq
import Control.Monad
import qualified Data.Traversable as Traversable
import Prelude (Bool(..), Maybe(..), Enum, Ord, ($), (<), Int, otherwise, (.))
import qualified Prelude

import Control.Concurrent.CHP

-- Temporary:
--import Control.Concurrent.CHP.Traces (labelMe)
labelMe :: Prelude.String -> a -> a
labelMe _ x = x

-- | Forever forwards the value onwards, unchanged.  Adding this to your process
-- network effectively adds a single-place buffer.
id :: (ReadableChannel r, Poisonable (r a),
       WriteableChannel w, Poisonable (w a)) => r a -> w a -> CHP ()
id in_ out = labelMe "Common.id" $ (forever $
  do x <- readChannel in_
     writeChannel out x
  ) `onPoisonRethrow` (poison in_ >> poison out)

-- | Forever forwards the value onwards.  This is
-- like 'id' but does not add any buffering to your network, and its presence
-- is indetectable to the process either side.
--
-- extId is a unit of the associative operator 'Control.Concurrent.CHP.Utils.|->|'.
extId :: Chanin a -> Chanout a -> CHP ()
extId in_ out = labelMe "Common.extId" $ do
  c <- oneToOneChannel
  forever (
    extReadChannel in_ (writeChannel (writer c))
    <&>
    extWriteChannel out (readChannel (reader c))
    ) `onPoisonRethrow` (poison in_ >> poison out)

-- | A process that waits for an input, then sends it out on /all/ its output
-- channels (in order) during an extended rendezvous.  This is often used to send the
-- output on to both the normal recipient (without introducing buffering) and
-- also to a listener process that wants to examine the value.  If the listener
-- process is first in the list, and does not take the input immediately, the
-- value will not be sent to the other recipients until it does.  The name
-- of the process derives from the notion of a wire-tap, since the listener
-- is hidden from the other processes (it does not visibly change the semantics
-- for them -- except when the readers of the channels are offering a choice).
tap :: Chanin a -> [Chanout a] -> CHP ()
tap in_ outs = (forever $
  extReadChannel in_
     (\x -> mapM_ (Prelude.flip writeChannel x) outs)
  ) `onPoisonRethrow` (poison in_ >> poisonAll outs)

-- | Sends out a single value first (the prefix) then behaves like id.
prefix :: a -> Chanin a -> Chanout a -> CHP ()
prefix x in_ out = labelMe "Common.prefix" $ (writeChannel out x >> id in_ out)
  `onPoisonRethrow` (poison in_ >> poison out)

-- | Discards the first value it receives then act likes id.
tail :: Chanin a -> Chanout a -> CHP ()
tail input output = (readChannel input `onPoisonRethrow` (poison input >> poison output))
                       >> id input output

-- | Forever reads in a value, and then sends out its successor (using 'Prelude.succ').
succ :: Enum a => Chanin a -> Chanout a -> CHP ()
succ = (labelMe "Common.succ" .) . map Prelude.succ

-- | Reads in a value, and sends it out in parallel on all the given output
-- channels.
parDelta :: Chanin a -> [Chanout a] -> CHP ()
parDelta in_ outs = labelMe "Common.parDelta" $ (forever $
  do x <- readChannel in_
     runParallel_ $ Prelude.map (Prelude.flip writeChannel x) outs
  ) `onPoisonRethrow` (poison in_ >> mapM_ poison outs)

-- | Forever reads in a value, transforms it using the given function, and sends it
-- out again.  Note that the transformation is not applied strictly, so don't
-- assume that this process will actually perform the computation.  If you
-- require a strict transformation, use 'map''.
map :: (a -> b) -> Chanin a -> Chanout b -> CHP ()
map f in_ out = labelMe "Common.map" $ forever (readChannel in_ >>= writeChannel out . f)
  `onPoisonRethrow` (poison in_ >> poison out)

-- | Like 'map', but applies the transformation strictly before sending on
-- the value.
map' :: NFData b => (a -> b) -> Chanin a -> Chanout b -> CHP ()
map' f in_ out = forever (readChannel in_ >>= writeChannelStrict out . f)
  `onPoisonRethrow` (poison in_ >> poison out)

-- | Forever reads in a value, and then based on applying the given function
-- either discards it (if the function returns False) or sends it on (if
-- the function returns True).
filter :: (a -> Bool) -> Chanin a -> Chanout a -> CHP ()
filter f in_ out = forever (do
  x <- readChannel in_
  when (f x) (writeChannel out x)
  ) `onPoisonRethrow` (poison in_ >> poison out)

-- | Streams all items in a 'Data.Traversable.Traversable' container out
-- in the order given by 'Data.Traversable.mapM' on the output channel (one at
-- a time).  Lists, 'Prelude.Maybe', and 'Data.Set.Set' are all instances
-- of 'Data.Traversable.Traversable', so this can be used for all of
-- those.
stream :: Traversable.Traversable t => Chanin (t a) -> Chanout a -> CHP ()
stream in_ out = (forever $ do
  xs <- readChannel in_
  Traversable.mapM (writeChannel out) xs)
  `onPoisonRethrow` (poison in_ >> poison out)

-- | Forever waits for input from one of its many channels and sends it
-- out again on the output channel.
merger :: [Chanin a] -> Chanout a -> CHP ()
merger ins out = (forever $ alt (Prelude.map readChannel ins) >>= writeChannel out)
  `onPoisonRethrow` (poisonAll ins >> poison out)

-- | Sends out the specified value on the given channel the specified number
-- of times, then finishes.
replicate :: Int -> a -> Chanout a -> CHP ()
replicate n x c = replicateM_ n (writeChannel c x) `onPoisonRethrow` poison c

-- | Forever sends out the same value on the given channel, until poisoned.
--  Similar to the white-hole processes in some other frameworks.
repeat :: a -> Chanout a -> CHP ()
repeat x c = (forever $ writeChannel c x) `onPoisonRethrow` poison c

-- | Forever reads values from the channel and discards them, until poisoned.
--  Similar to the black-hole processes in some other frameworks.
consume :: Chanin a -> CHP ()
consume c = (forever $ readChannel c) `onPoisonRethrow` poison c

-- | For the duration of the given process, acts as a consume process, but stops
-- when the given process stops.  Note that there could be a timing issue where
-- extra inputs are consumed at the end of the lifetime of the process.
-- Note also that while poison from the given process will be propagated on the
-- consumption channel, there is no mechanism to propagate poison from the consumption
-- channel into the given process.
consumeAlongside :: Chanin a -> CHP b -> CHP b
consumeAlongside in_ proc
  = do c <- oneToOneChannel' $ chanLabel "consumeAlongside-Internal"
       (x,_) <- 
         ((do x <- proc
              writeChannel (writer c) ()
              return x
          ) `onPoisonRethrow` poison (writer c))
         <||>
         (inner (reader c) `onPoisonRethrow` poison (reader c))
       return x
  where
    inner c = do cont <- alt
                   [readChannel c >> return False
                   ,readChannel in_ >> return True
                   ]
                 when cont (inner c)

-- | Forever reads a value from both its input channels in parallel, then joins
-- the two values using the given function and sends them out again.  For example,
-- @join (,) c d@ will pair the values read from @c@ and @d@ and send out the
-- pair on the output channel, whereas @join (&&)@ will send out the conjunction
-- of two boolean values, @join (==)@ will read two values and output whether
-- they are equal or not, etc.
join :: (a -> b -> c) -> Chanin a -> Chanin b -> Chanout c -> CHP ()
join f in0 in1 out = (forever $ do
  [Prelude.Left x, Prelude.Right y] <- runParallel
    [liftM Prelude.Left $ readChannel in0, liftM Prelude.Right $ readChannel in1]
  writeChannel out $ f x y
  ) `onPoisonRethrow` (poison in0 >> poison in1 >> poison out)

-- | Forever reads a value from all its input channels in parallel, then joins
-- the values into a list in the same order as the channels, and sends them out again.
joinList :: [Chanin a] -> Chanout [a] -> CHP ()
joinList ins out = (forever $ runParMapM readChannel ins >>= writeChannel out
  ) `onPoisonRethrow` (poisonAll ins >> poison out)


-- | Forever reads a pair from its input channel, then in parallel sends out
-- the first and second parts of the pair on its output channels.
split :: Chanin (a, b) -> Chanout a -> Chanout b -> CHP ()
split in_ outA outB = (forever $ do
  (a, b) <- readChannel in_
  writeChannel outA a <||> writeChannel outB b
  ) `onPoisonRethrow` (poison in_ >> poison outA >> poison outB)

-- | A sorter process.  When it receives its first @Just x@ data item, it keeps
-- it.  When it receieves a second, it keeps the lowest of the two, and sends
-- out the other one.  When it receives Nothing, it sends out its data value,
-- then sends Nothing too.  The overall effect when chaining these things together
-- is a sorting pump.  You inject all the values with Just, then send in a
-- single Nothing to get the results out (in reverse order).
sorter :: Ord a => Chanin (Maybe a) -> Chanout (Maybe a) -> CHP ()
sorter = sorter' (<)

-- | Like sorter, but with a custom comparison method.  You should pass in
-- the equivalent of less-than: (<).
sorter' :: forall a. (a -> a -> Bool) -> Chanin (Maybe a) -> Chanout (Maybe a) -> CHP ()
sorter' lt in_ out = internal Nothing `onPoisonRethrow` (poison in_ >> poison out)
  where
    internal :: Maybe a -> CHP ()
    internal curVal = do newVal <- readChannel in_
                         case (curVal, newVal) of
                           -- Flush, but we're empty:
                           (Nothing, Nothing) -> do writeChannel out newVal
                                                    internal curVal
                           -- Flush:
                           (Just _, Nothing) -> do writeChannel out curVal
                                                   writeChannel out newVal
                                                   internal curVal
                           -- New value, we were empty:
                           (Nothing, Just _) -> internal newVal
                           -- New value, we had one already:
                           (Just cur, Just new)
                             | new `lt` cur -> do writeChannel out curVal
                                                  internal newVal
                             | otherwise -> do writeChannel out newVal
                                               internal curVal

-- | A shared variable process.  Given an initial value and two channels, it
-- continually offers to output its current value or read in a new one.
valueStore :: (ReadableChannel r, Poisonable (r a),
               WriteableChannel w, Poisonable (w a)) =>
               a -> r a -> w a -> CHP ()
valueStore val input output
  = inner val `onPoisonRethrow` (poison input >> poison output)
  where
    inner x = ((writeChannel output x >> return x) <-> readChannel input) >>= inner

-- | A shared variable process.  The same as valueStore, but initially waits
-- to read its starting value before then offering to either output its current
-- value or read in a new one.
valueStore' :: (ReadableChannel r, Poisonable (r a),
               WriteableChannel w, Poisonable (w a)) => r a -> w a -> CHP ()
valueStore' input output
  = (readChannel input >>= \x -> valueStore x input output)
      `onPoisonRethrow` (poison input >> poison output)

-- | Continually waits for a specific time on the given clock, each time applying
-- the function to work out the next specific time to wait for.  The most common
-- thing to pass is Prelude.succ or (+1).
advanceTime :: (Waitable c, Ord t) => (t -> t) -> Enrolled c t -> CHP ()
advanceTime f c = do t <- getCurrentTime c
                     inner (f t)
  where
    inner t = wait c (Just t) >>= inner . f
