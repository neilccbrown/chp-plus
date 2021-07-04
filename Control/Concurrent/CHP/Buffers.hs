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


-- | Various processes that act like buffers.  Poisoning either end of a buffer
-- process is immediately passed on to the other side, in contrast to C++CSP2
-- and JCSP.
module Control.Concurrent.CHP.Buffers (fifoBuffer, infiniteBuffer,
  accumulatingInfiniteBuffer, overflowingBuffer, overwritingBuffer)
  where

import Control.Monad
import Data.Foldable
import Data.Sequence (Seq, viewl, ViewL(..))
import qualified Data.Sequence as Seq

import Control.Concurrent.CHP
import qualified Control.Concurrent.CHP.Common as Common

-- | Acts like a limited capacity FIFO buffer of the given size.  When it is
-- full it accepts no input, and when it is empty it offers no output.
fifoBuffer :: forall a. Int -> Chanin a -> Chanout a -> CHP ()
fifoBuffer n in_ out
  | n < 0     = return ()
  | n == 0    = Common.id in_ out
  | otherwise = fifo Seq.empty `onPoisonRethrow` (poison in_ >> poison out)
  where
    fifo :: Seq a -> CHP ()
    fifo s | Seq.null s = takeIn
           | Seq.length s == n = sendOut
           | otherwise = takeIn <-> sendOut
      where
        takeIn = readChannel in_ >>= fifo . addLast s
        sendOut = do writeChannel out (seqHead s)
                     fifo (removeHead s)

-- | Acts like a FIFO buffer with unlimited capacity.  Use with caution; make
-- sure you do not let the buffer grow so large that it eats up all your memory.
--  When it is empty, it offers no output.  It always accepts input.
infiniteBuffer :: forall a. Chanin a -> Chanout a -> CHP ()
infiniteBuffer in_ out
  = buff Seq.empty `onPoisonRethrow` (poison in_ >> poison out)
  where
    buff :: Seq a -> CHP ()
    buff s | Seq.null s = takeIn
           | otherwise = sendOut </> takeIn
      where
        takeIn = readChannel in_ >>= buff . addLast s
        sendOut = do writeChannel out (seqHead s)
                     buff (removeHead s)

-- | Acts like a FIFO buffer with unlimited capacity, but accumulates
-- sequential inputs into a list which it offers in a single output.  Use with
-- caution; make sure you do not let the buffer grow so large that it eats up
-- all your memory.  When it is empty, it offers the empty list.  It always
-- accepts input.  Once it has sent out a value (or values) it removes them
-- from its internal storage.
accumulatingInfiniteBuffer :: forall a. Chanin a -> Chanout [a] -> CHP ()
accumulatingInfiniteBuffer in_ out
  = buff Seq.empty `onPoisonRethrow` (poison in_ >> poison out)
  where
    buff :: Seq a -> CHP ()
    buff s = (sendOut </> takeIn) >>= buff
      where
        takeIn = liftM (addLast s) $ readChannel in_ 
        sendOut = do writeChannel out (toList s)
                     return Seq.empty


-- | Acts like a FIFO buffer of limited capacity, except that when it is full,
-- it always accepts input and discards it.  When it is empty, it does not offer output.
overflowingBuffer :: forall a. Int -> Chanin a -> Chanout a -> CHP ()
overflowingBuffer n in_ out
  | n < 0     = return ()
  | n == 0    = Common.id in_ out
  | otherwise = flow Seq.empty `onPoisonRethrow` (poison in_ >> poison out)
  where
    flow :: Seq a -> CHP ()
    flow s | Seq.null s = takeIn
           | Seq.length s == n = sendOut <-> dropItem
           | otherwise = takeIn <-> sendOut
      where
        takeIn = readChannel in_ >>= flow . addLast s
        dropItem = readChannel in_ >> flow s
        sendOut = do writeChannel out (seqHead s)
                     flow (removeHead s)

-- | Acts like a FIFO buffer of limited capacity, except that when it is full,
-- it always accepts input and pushes out the oldest item in the buffer.  When
-- it is empty, it does not offer output.
overwritingBuffer :: forall a. Int -> Chanin a -> Chanout a -> CHP ()
overwritingBuffer n in_ out
  | n < 0     = return ()
  | n == 0    = Common.id in_ out
  | otherwise = over Seq.empty `onPoisonRethrow` (poison in_ >> poison out)
  where
    over :: Seq a -> CHP ()
    over s | Seq.null s = takeIn
           | Seq.length s == n = sendOut <-> takeInOver
           | otherwise = takeIn <-> sendOut
      where
        takeIn = readChannel in_ >>= over . addLast s
        takeInOver = readChannel in_ >>= over . removeHead . addLast s
        sendOut = do writeChannel out (seqHead s)
                     over (removeHead s)

seqHead :: Seq a -> a
seqHead s = case viewl s of
  EmptyL -> error "Internal code logic error in buffer"
  x :< _ -> x

removeHead :: Seq a -> Seq a
removeHead = Seq.drop 1

addLast :: Seq a -> a -> Seq a
addLast = (Seq.|>)
