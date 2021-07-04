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

-- | Contains a process for easily using stdin, stdout and stderr as channels.
module Control.Concurrent.CHP.Console where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Control.Exception.Extensible as C
import Control.Monad
--import Data.Maybe
import System.IO

import Control.Concurrent.CHP

-- | A set of channels to be given to the process to run, containing channels
-- for stdin, stdout and stderr.
data ConsoleChans = ConsoleChans { cStdin :: Chanin Char, cStdout :: Chanout
  Char, cStderr :: Chanout Char }

-- | A function for running the given CHP process that wants console channels.
-- When your program finishes, the console channels are automatically poisoned,
-- but it's good practice to poison them yourself when you finish.  Only ever
-- run one of these processes at a time, or undefined behaviour will result.
--
-- When using this process, due to the way that the console handlers are terminated,
-- you may sometimes see a notice that a thread was killed.  This is normal behaviour
-- (unfortunately).
consoleProcess :: (ConsoleChans -> CHP ()) -> CHP ()
consoleProcess mainProc
  = do [cin, cout, cerr] <- replicateM 3 oneToOneChannel
       tvs@[tvinId, tvoutId, tverrId] <- liftIO_CHP $ atomically $ replicateM 3 $ newTVar Nothing
       runParallel_
         [ inHandler tvinId (writer cin)
         , outHandler tvoutId stdout (reader cout)
         , outHandler tverrId stderr (reader cerr)
         , do ids <- mapM getId tvs
              (mainProc $ ConsoleChans (reader cin) (writer cout) (writer cerr))
                `onPoisonTrap` (return ())
              poison (reader cin)
              poison (writer cout)
              poison (writer cerr)
              -- Poison won't do it if the handlers are blocked on input or
              -- output.  Therefore we throw them an exception to "knock them
              -- off" their current action and make them exit.
              liftIO_CHP yield
              liftIO_CHP $ mapM_ killThread ids
         ]
  where
    getId :: TVar (Maybe a) -> CHP a
    getId tv = liftIO_CHP $ atomically $ readTVar tv >>= maybe retry return

    -- Like liftIO, but turns any caught exceptions into throwing poison
    liftIO' :: IO a -> CHP a
    liftIO' m = liftIO_CHP (liftM Just m `C.catches` handlers)
      >>= maybe throwPoison return
      where
        response :: C.Exception e => e -> IO (Maybe a)
        response = const $ return Nothing

        handlers = [C.Handler (response :: C.IOException -> IO (Maybe a))
                   ,C.Handler (response :: C.AsyncException -> IO (Maybe a))
#if __GLASGOW_HASKELL__ >= 611
                   ,C.Handler (response :: C.BlockedIndefinitelyOnSTM -> IO (Maybe a))
#else
                   ,C.Handler (response :: C.BlockedIndefinitely -> IO (Maybe a))
#endif
                   ,C.Handler (response :: C.Deadlock -> IO (Maybe a))
                   ]
    
    inHandler :: TVar (Maybe ThreadId) -> Chanout Char -> CHP ()
    inHandler tv c
      = do liftIO_CHP $ myThreadId >>= atomically . writeTVar tv . Just
           if rtsSupportsBoundThreads
             then (forever $ do ready <- liftIO_CHP $ hWaitForInput stdin 100
                                checkForPoison c
                                when ready $
                                  liftIO' getChar >>= writeChannel c)
                    `onPoisonTrap` poison c
             else (forever $ liftIO' getChar >>= writeChannel c)
                    `onPoisonTrap` poison c

    outHandler :: TVar (Maybe ThreadId) -> Handle -> Chanin Char -> CHP ()
    outHandler tv h c
      = do liftIO_CHP $ myThreadId >>= atomically . writeTVar tv . Just
           (forever $ readChannel c >>= liftIO' . hPutChar h)
             `onPoisonTrap` poison c
