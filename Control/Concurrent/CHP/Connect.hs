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

-- | A module of operators for connecting processes together.
module Control.Concurrent.CHP.Connect
  (Connectable(..), (<=>), (|<=>), (<=>|), (|<=>|), pipelineConnect, pipelineConnectComplete,
    cycleConnect, connectList, connectList_, ChannelPair,
    ConnectableExtra(..), connectWith) where

import Control.Applicative
import Control.Arrow

import Control.Concurrent.CHP

-- | Like 'Connectable', but allows an extra parameter.
--
-- The API (and name) for this is still in flux, so do not rely on it just yet.
class ConnectableExtra l r where
  type ConnectableParam l r
  -- | Runs the given code with the two items connected.
  connectExtra :: ConnectableParam l r -> ((l, r) -> CHP ()) -> CHP ()

-- | Indicates that its two parameters can be joined together automatically.
--
-- Rather than use 'connect' directly, you will want to use the operators such
-- as '(<=>)'.  There are different forms of this operator for in the middle of
-- a pipeline (where you still need further parameters to each process), and at
-- the ends.  See also 'pipelineConnect' and 'pipelineConnectComplete'.
class Connectable l r where
  -- | Runs the given code with the two items connected.
  connect :: ((l, r) -> CHP a) -> CHP a

-- | A pair of channels.  The main use of this type is with the Connectable class,
-- as it allows you to wire together two processes that take the exact same channel
-- pair, e.g. both are of type @ChannelPair (Chanin Int) (Chanout Int) -> CHP ()@.  With the
-- normal Connectable pair instances, one would need to be of type @(Chanin Int,
-- Chanout Int) -> CHP ()@, and the other of type @(Chanout Int, Chanin Int) ->
-- CHP ()@.
data ChannelPair l r = ChannelPair l r
  deriving (Eq, Show)

instance Connectable l r => Connectable (ChannelPair l r) (ChannelPair l r) where
  connect f = connect $ \(lx, rx) -> connect $ \(ly, ry) -> 
    f (ChannelPair lx ry, ChannelPair ly rx)

-- | Like 'connect', but provides the process a list of items of the specified size,
-- and runs it.
connectList :: Connectable l r => Int -> ([(l, r)] -> CHP a) -> CHP a
connectList n p | n == 0 = p []
                | n > 0 = connect $ \lr -> connectList (n - 1) $ p . (lr :)
                | otherwise = error $ "Control.Concurrent.CHP.Connect.connectList: negative parameter " ++ show n

-- | Like 'connectList' but ignores the results.
connectList_ :: Connectable l r => Int -> ([(l, r)] -> CHP a) -> CHP ()
connectList_ n p | n == 0 = p [] >> return ()
                 | n > 0 = connect $ \lr -> connectList_ (n - 1) $ p . (lr :)
                 | otherwise = error $ "Control.Concurrent.CHP.Connect.connectList_: negative parameter " ++ show n

-- | Joins together the given two processes and runs them in parallel.
(|<=>|) :: Connectable l r => (l -> CHP ()) -> (r -> CHP ()) -> CHP ()
(|<=>|) p q = connect $ \(x, y) -> p x <|*|> q y

jpo :: ConnectableExtra l r => ConnectableParam l r -> (l -> CHP ()) -> (r -> CHP ()) -> CHP ()
jpo o p q = connectExtra o $ \(x, y) -> p x <|*|> q y

-- | Joins together the given two processes and runs them in parallel.
(<=>) :: Connectable l r => (a -> l -> CHP ()) -> (r -> b -> CHP ()) -> a -> b -> CHP ()
(<=>) p q x y = p x |<=>| flip q y

-- | Joins together the given two processes and runs them in parallel.
(<=>|) :: Connectable l r => (a -> l -> CHP ()) -> (r -> CHP ()) -> a -> CHP ()
(<=>|) p q x = p x |<=>| q

-- | Joins together the given two processes and runs them in parallel.
(|<=>) :: Connectable l r => (l -> CHP ()) -> (r -> b -> CHP ()) -> b -> CHP ()
(|<=>) p q x = p |<=>| flip q x

-- | Like '(<=>)' but with 'ConnectableExtra'
connectWith :: ConnectableExtra l r => ConnectableParam l r ->
  (a -> l -> CHP ()) -> (r -> b -> CHP ()) -> a -> b -> CHP ()
connectWith o p q x y = jpo o (p x) (flip q y)

-- | Like @foldl1 (<=>)@; connects a pipeline of processes together.  If the list
-- is empty, it returns a process that ignores both its arguments and returns instantly.
pipelineConnect :: Connectable l r => [r -> l -> CHP ()] -> r -> l -> CHP ()
pipelineConnect [] = const . const $ return ()
pipelineConnect ps = foldl1 (<=>) ps

-- | Connects the given beginning process, the list of middle processes, and
-- the end process into a pipeline and runs them all in parallel.  If the list
-- is empty, it connects the beginning directly to the end.
pipelineConnectComplete :: Connectable l r =>
  (l -> CHP ()) -> [r -> l -> CHP ()] -> (r -> CHP ()) -> CHP ()
pipelineConnectComplete begin middle end
  = (foldl (|<=>) begin middle) |<=>| end

-- | Like 'pipelineConnect' but also connects the last process into the first.
--  If the list is empty, it returns immediately.
cycleConnect :: Connectable l r => [r -> l -> CHP ()] -> CHP ()
cycleConnect [] = return ()
cycleConnect ps = connect . uncurry . flip . pipelineConnect $ ps

instance Connectable (Chanout a) (Chanin a) where
  connect = (newChannelWR >>=)
instance ConnectableExtra (Chanout a) (Chanin a) where
  type ConnectableParam (Chanout a) (Chanin a) = ChanOpts a
  connectExtra o = (>>=) ((writer &&& reader) <$> oneToOneChannel' o)

instance Connectable (Chanin a) (Chanout a) where
  connect = (newChannelRW >>=)
instance ConnectableExtra (Chanin a) (Chanout a) where
  type ConnectableParam (Chanin a) (Chanout a) = ChanOpts a
  connectExtra o = (>>=) ((reader &&& writer) <$> oneToOneChannel' o)

instance Connectable (Shared Chanin a) (Chanout a) where connect = (newChannelRW >>=)
instance Connectable (Chanin a) (Shared Chanout a) where connect = (newChannelRW >>=)
instance Connectable (Shared Chanin a) (Shared Chanout a) where connect = (newChannelRW >>=)

instance Connectable (Chanout a) (Shared Chanin a) where connect = (newChannelWR >>=)
instance Connectable (Shared Chanout a) (Chanin a) where connect = (newChannelWR >>=)
instance Connectable (Shared Chanout a) (Shared Chanin a) where connect = (newChannelWR >>=)

instance ConnectableExtra (Chanout a) (Shared Chanin a) where
  type ConnectableParam (Chanout a) (Shared Chanin a) = ChanOpts a
  connectExtra o = (>>=) ((writer &&& reader) <$> oneToAnyChannel' o)
instance ConnectableExtra (Shared Chanout a) (Chanin a) where
  type ConnectableParam (Shared Chanout a) (Chanin a) = ChanOpts a
  connectExtra o = (>>=) ((writer &&& reader) <$> anyToOneChannel' o)
instance ConnectableExtra (Shared Chanout a) (Shared Chanin a) where
  type ConnectableParam (Shared Chanout a) (Shared Chanin a) = ChanOpts a
  connectExtra o = (>>=) ((writer &&& reader) <$> anyToAnyChannel' o)

instance ConnectableExtra (Shared Chanin a) (Chanout a) where
  type ConnectableParam (Shared Chanin a) (Chanout a) = ChanOpts a
  connectExtra o = (>>=) ((reader &&& writer) <$> oneToAnyChannel' o)
instance ConnectableExtra (Chanin a) (Shared Chanout a) where
  type ConnectableParam (Chanin a) (Shared Chanout a) = ChanOpts a
  connectExtra o = (>>=) ((reader &&& writer) <$> anyToOneChannel' o)
instance ConnectableExtra (Shared Chanin a) (Shared Chanout a) where
  type ConnectableParam (Shared Chanin a) (Shared Chanout a) = ChanOpts a
  connectExtra o = (>>=) ((reader &&& writer) <$> anyToAnyChannel' o)




instance Connectable (Enrolled PhasedBarrier ()) (Enrolled PhasedBarrier ()) where
  connect m = do b <- newBarrier
                 enroll b $ \b0 -> enroll b $ \b1 -> m (b0, b1)

instance ConnectableExtra (Enrolled PhasedBarrier ph) (Enrolled PhasedBarrier ph) where
  type ConnectableParam (Enrolled PhasedBarrier ph) (Enrolled PhasedBarrier ph) = (ph, BarOpts ph)
  connectExtra (ph, o) m
    = do b <- newPhasedBarrier' ph o
         enroll b $ \b0 -> enroll b $ \b1 -> m (b0, b1)


instance (Connectable al ar, Connectable bl br) => Connectable (al, bl) (ar, br) where
  connect m = connect $ \(ax, ay) -> connect $ \(bx, by) -> m ((ax, bx), (ay, by))
instance (ConnectableExtra al ar, ConnectableExtra bl br) => ConnectableExtra (al, bl) (ar, br) where
  type ConnectableParam (al, bl) (ar, br) = (ConnectableParam al ar, ConnectableParam bl br)
  connectExtra (ao, bo) m = connectExtra ao $ \(ax, ay) -> connectExtra bo $ \(bx, by) -> m ((ax, bx), (ay, by))

instance (Connectable al ar, Connectable bl br, Connectable cl cr) =>
          Connectable (al, bl, cl) (ar, br, cr) where
  connect m = connect $ \(ax, ay) -> connect $ \(bx, by) ->
              connect $ \(cx, cy) -> m ((ax, bx, cx), (ay, by, cy))

instance (ConnectableExtra al ar, ConnectableExtra bl br, ConnectableExtra cl cr) =>
  ConnectableExtra (al, bl, cl) (ar, br, cr) where
  type ConnectableParam (al, bl, cl) (ar, br, cr) = (ConnectableParam al ar, ConnectableParam bl br, ConnectableParam cl cr)
  connectExtra (ao, bo, co) m
    = connectExtra ao $ \(ax, ay) -> connectExtra bo $ \(bx, by) ->
      connectExtra co $ \(cx, cy) -> m ((ax, bx, cx), (ay, by, cy))

instance (Connectable al ar, Connectable bl br, Connectable cl cr,
          Connectable dl dr) =>
          Connectable (al, bl, cl, dl) (ar, br, cr, dr) where
  connect m = connect $ \(ax, ay) -> connect $ \(bx, by) ->
              connect $ \(cx, cy) -> connect $ \(dx, dy) ->
                m ((ax, bx, cx, dx), (ay, by, cy, dy))
instance (ConnectableExtra al ar, ConnectableExtra bl br, ConnectableExtra cl cr,
          ConnectableExtra dl dr) =>
          ConnectableExtra (al, bl, cl, dl) (ar, br, cr, dr) where
  type ConnectableParam (al, bl, cl, dl) (ar, br, cr, dr)
    = (ConnectableParam al ar,
       ConnectableParam bl br,
       ConnectableParam cl cr,
       ConnectableParam dl dr)
  connectExtra (ao, bo, co, do_) m
    = connectExtra ao $ \(ax, ay) -> connectExtra bo $ \(bx, by) ->
      connectExtra co $ \(cx, cy) -> connectExtra do_ $ \(dx, dy) ->
        m ((ax, bx, cx, dx), (ay, by, cy, dy))

instance (Connectable al ar, Connectable bl br, Connectable cl cr,
          Connectable dl dr, Connectable el er) =>
          Connectable (al, bl, cl, dl, el) (ar, br, cr, dr, er) where
  connect m = connect $ \(ax, ay) -> connect $ \(bx, by) ->
              connect $ \(cx, cy) -> connect $ \(dx, dy) ->
              connect $ \(ex, ey) -> m ((ax, bx, cx, dx, ex), (ay, by, cy, dy, ey))
instance (ConnectableExtra al ar, ConnectableExtra bl br, ConnectableExtra cl cr,
          ConnectableExtra dl dr, ConnectableExtra el er) =>
          ConnectableExtra (al, bl, cl, dl, el) (ar, br, cr, dr, er) where
  type ConnectableParam (al, bl, cl, dl, el) (ar, br, cr, dr, er)
    = (ConnectableParam al ar,
       ConnectableParam bl br,
       ConnectableParam cl cr,
       ConnectableParam dl dr,
       ConnectableParam el er)
  connectExtra (ao, bo, co, do_, eo) m
    = connectExtra ao $ \(ax, ay) -> connectExtra bo $ \(bx, by) ->
      connectExtra co $ \(cx, cy) -> connectExtra do_ $ \(dx, dy) ->
        connectExtra eo $ \(ex, ey) -> m ((ax, bx, cx, dx, ex), (ay, by, cy, dy, ey))

