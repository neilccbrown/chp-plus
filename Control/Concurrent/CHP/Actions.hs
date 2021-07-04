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

-- | A module containing action wrappers around channel-ends.
--
-- In CHP, there are a variety of channel-ends.  Enrolled Chanin, Shared Chanout,
-- plain Chanin, and so on.  The difference between these ends can be important;
-- enrolled channel-ends can be resigned from, shared channel-ends need to be claimed
-- before use.  But sometimes you just want to ignore those differences and read
-- and write from the channel-end regardless of its type.  In particular, you want
-- to pass a channel-end to a process without the process worrying about its type.
--
-- Actions allow you to do this.  A send action is like a monadic function (@a
-- -> CHP()@) for sending an item, but can be poisoned too.  A recv action is like
-- something of type @CHP a@ that again can be poisoned.
module Control.Concurrent.CHP.Actions
  ( SendAction, RecvAction,
    sendAction, recvAction,
    makeSendAction, makeRecvAction,
    makeSendAction', makeRecvAction',
    makeCustomSendAction, makeCustomRecvAction,
    nullSendAction, nullRecvAction
  ) where

import Control.Concurrent.CHP
import Control.Monad

-- | A send action.  See 'sendAction'.  Note that it is poisonable.
newtype SendAction a = SendAction (a -> CHP (), CHP (), CHP ())
-- | A receive action.  See 'recvAction'.  Note that it is poisonable.
newtype RecvAction a = RecvAction (CHP a, CHP (), CHP ())

-- | Sends a data item using the given sendAction.  Whether this operation can
-- be used in a choice (see 'alt') is entirely dependent on whether the original
-- action could be used in an alt.  For all of CHP's channels, this is true, but
-- for your own custom send actions, probably not.
sendAction :: SendAction a -> a -> CHP ()
sendAction (SendAction (s, _, _)) = s

-- | Receives a data item using the given recvAction.  Whether this operation can
-- be used in a choice (see 'alt') is entirely dependent on whether the original
-- action could be used in an alt.  For all of CHP's channels, this is true, but
-- for your own custom receive actions, probably not.
recvAction :: RecvAction a -> CHP a
recvAction (RecvAction (s, _, _)) = s

instance Poisonable (SendAction c) where
  poison (SendAction (_,p,_)) = liftCHP p
  checkForPoison (SendAction (_,_,c)) = liftCHP c

instance Poisonable (RecvAction c) where
  poison (RecvAction (_,p,_)) = liftCHP p
  checkForPoison (RecvAction (_,_,c)) = liftCHP c

-- | Given a writing channel end, gives back the corresponding 'SendAction'.
makeSendAction :: (WriteableChannel w, Poisonable (w a)) => w a -> SendAction a
makeSendAction c = SendAction (writeChannel c, poison c, checkForPoison c)

-- | Like 'makeSendAction', but always applies the given function before sending
-- the item.
makeSendAction' :: (WriteableChannel w, Poisonable (w b)) =>
  w b -> (a -> b) -> SendAction a
makeSendAction' c f = SendAction (writeChannel c . f, poison c, checkForPoison c)

-- | Given a reading channel end, gives back the corresponding 'RecvAction'.
makeRecvAction :: (ReadableChannel r, Poisonable (r a)) => r a -> RecvAction a
makeRecvAction c = RecvAction (readChannel c, poison c, checkForPoison c)

-- | Like 'makeRecvAction', but always applies the given function after receiving
-- an item.
makeRecvAction' :: (ReadableChannel r, Poisonable (r a)) =>
  r a -> (a -> b) -> RecvAction b
makeRecvAction' c f = RecvAction (liftM f $ readChannel c, poison c, checkForPoison c)

-- | Creates a custom send operation.  The first parameter should perform the send,
-- the second parameter should poison your communication channel, and the third
-- parameter should check whether the communication channel is already poisoned.
--  Generally, you will want to use 'makeSendAction' instead of this function.
makeCustomSendAction :: (a -> CHP ()) -> CHP () -> CHP () -> SendAction a
makeCustomSendAction x y z = SendAction (x, y, z)

-- | Creates a custom receive operation.  The first parameter should perform the receive,
-- the second parameter should poison your communication channel, and the third
-- parameter should check whether the communication channel is already poisoned.
--  Generally, you will want to use 'makeRecvAction' instead of this function.
makeCustomRecvAction :: CHP a -> CHP () -> CHP () -> RecvAction a
makeCustomRecvAction x y z = RecvAction (x, y, z)

-- | Acts like a SendAction, but just discards the data.
nullSendAction :: SendAction a
nullSendAction = SendAction (const $ return (), return (), return ())

-- | Acts like a RecvAction, but always gives back the given data item.
nullRecvAction :: a -> RecvAction a
nullRecvAction x = RecvAction (return x, return (), return ())

