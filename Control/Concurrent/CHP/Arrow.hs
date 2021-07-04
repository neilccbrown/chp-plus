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


-- | Provides an instance of Arrow for process pipelines.  As described in
-- the original paper on arrows, they can be used to represent stream processing,
-- so CHP seemed like a possible fit for an arrow.
-- 
-- Whether this is /actually/ an instance of Arrow depends on technicalities.
--  This can be demonstrated with the arrow law @arr id >>> f = f = f >>> arr
-- id@.  Whether CHP satisfies this arrow law depends on the definition of
-- equality.
--
-- * If equality means that given the same input value, both arrows produce the
-- same corresponding output value, this is an arrow.
--
-- * If equality means you give the arrows the same single input and wait for the single output,
-- and the output is the same, this is an arrow.
--
-- * If equality means that you can feed the arrows lots of inputs (one after
-- the other) and the behaviour should be the same with regards to communication,
-- this is not an arrow.
--
-- The problem lies in the buffering inherent in arrows.  Imagine if @f@ is
-- a single function.  @f@ is effectively a buffer of one.  You can feed it
-- a single value, but no more than that until you read its output.  However,
-- if you have @arr id >>> f@, that can accept two inputs (one held by the
-- @arr id@ process and one held by @f@) before you must accept the output.
--
-- I am fairly confident that the arrow laws are satisfied for the
-- definition of equality that given the same single input, they will
-- produce the same single output.  If you don't worry too much about the
-- behavioural difference, and just take arrows as another way to wire
-- together a certain class of process network, you should do fine.
module Control.Concurrent.CHP.Arrow (ProcessPipeline, runPipeline, arrowProcess, arrStrict,
  ProcessPipelineLabel, runPipelineLabel, arrowProcessLabel, arrLabel, arrStrictLabel,
  (*>>>*), (*<<<*), (*&&&*), (*****)) where

-- I have got this module to work on GHC 6.8 and 6.10 by following the CPP-variant
-- instructions on this page: http://haskell.org/haskellwiki/Upgrading_packages

import Control.Arrow
import Control.Category
import Prelude hiding ((.), id)
import Control.DeepSeq
import Control.Monad


import Control.Concurrent.CHP
import qualified Control.Concurrent.CHP.Common as CHP
import Control.Concurrent.CHP.Connect

-- | ProcessPipelineLabel is a version of 'ProcessPipeline' that allows the processes
-- to be labelled, and thus in turn for the channels connecting the processes to
-- be automatically labelled.  ProcessPipelineLabel is not an instance of Arrow,
-- but it does have a lot of similarly named functions for working with it.  This
-- awkwardness is due to the extra Show constraints on the connectors that allow
-- the arrow's contents to appear in traces.
--
-- If you don't use traces, use 'ProcessPipeline'.  If you do use traces, and want
-- to have better labels on the process and values used in your arrows, consider
-- switching to ProcessPipelineLabel.
data ProcessPipelineLabel a b = ProcessPipelineLabel
  { runPipelineLabel :: Chanin a -> Chanout b -> CHP ()
    -- ^ Like 'runPipeline' but for 'ProcessPipelineLabel'
  , _pipelineLabels :: (String, String)
  }

-- | Like 'arrowProcess', but allows the process to be labelled.  The same
-- warnings as 'arrowProcess' apply.
arrowProcessLabel :: String -> (Chanin a -> Chanout b -> CHP ()) -> ProcessPipelineLabel a b
arrowProcessLabel l p = ProcessPipelineLabel p (l, l)

-- | Like 'arr' for 'ProcessPipeline', but allows the process to be labelled.
arrLabel :: String -> (a -> b) -> ProcessPipelineLabel a b
arrLabel l = arrowProcessLabel l . CHP.map

-- | Like 'arrStrict', but allows the process to be labelled.
arrStrictLabel :: NFData b => String -> (a -> b) -> ProcessPipelineLabel a b
arrStrictLabel l = arrowProcessLabel l . CHP.map'

-- | The '(>>>)' arrow combinator, for 'ProcessPipelineLabel'.
(*>>>*) :: Show b => ProcessPipelineLabel a b -> ProcessPipelineLabel b c
  -> ProcessPipelineLabel a c
(*>>>*) (ProcessPipelineLabel p (pl, pr)) (ProcessPipelineLabel q (ql, qr))
  = ProcessPipelineLabel (connectWith (chanLabel $ pr ++ "->" ++ ql) p q) (pl, qr)

-- | The '(<<<)' arrow combinator, for 'ProcessPipelineLabel'.
(*<<<*) :: Show b => ProcessPipelineLabel b c -> ProcessPipelineLabel a b
  -> ProcessPipelineLabel a c
(*<<<*) = flip (*>>>*)

-- | The '(&&&)' arrow combinator, for 'ProcessPipelineLabel'.
(*&&&*) :: (Show b, Show c, Show c') => ProcessPipelineLabel b c -> ProcessPipelineLabel b c' -> ProcessPipelineLabel b (c, c')
(*&&&*) (ProcessPipelineLabel p (pl, pr))
        (ProcessPipelineLabel q (ql, qr))
  = ProcessPipelineLabel proc (mix pl ql, mix pr qr)
  where
    mix a b = "(" ++ a ++ "*&&&*" ++ b ++ ")"
    proc input output
       = do deltaP <- oneToOneChannel' $ chanLabel $ pl ++ ".in"
            deltaQ <- oneToOneChannel' $ chanLabel $ ql ++ ".in"
            joinP <- oneToOneChannel' $ chanLabel $ pr ++ ".out"
            joinQ <- oneToOneChannel' $ chanLabel $ qr ++ ".out"
            runParallel_
              [CHP.parDelta input (writers [deltaP, deltaQ])
              ,p (reader deltaP) (writer joinP)
              ,q (reader deltaQ) (writer joinQ)
              ,CHP.join (,) (reader joinP) (reader joinQ) output
              ]

-- | The '(***)' arrow combinator, for 'ProcessPipelineLabel'.
(*****) :: (Show b, Show b', Show c, Show c') => ProcessPipelineLabel b c -> ProcessPipelineLabel b' c'
  -> ProcessPipelineLabel (b, b') (c, c')
(*****) (ProcessPipelineLabel p (pl, pr))
        (ProcessPipelineLabel q (ql, qr))
  = ProcessPipelineLabel proc (mix pl ql, mix pr qr)
  where
    mix a b = "(" ++ a ++ "*****" ++ b ++ ")"
    proc input output
       = do deltaP <- oneToOneChannel' $ chanLabel $ mix pl ql ++ "->" ++ pl
            deltaQ <- oneToOneChannel' $ chanLabel $ mix pl ql ++ "->" ++ ql
            joinP <- oneToOneChannel' $ chanLabel $ pr ++ "->" ++ mix pr qr
            joinQ <- oneToOneChannel' $ chanLabel $ qr ++ "->" ++ mix pr qr
            runParallel_
              [CHP.split input (writer deltaP) (writer deltaQ)
              ,p (reader deltaP) (writer joinP)
              ,q (reader deltaQ) (writer joinQ)
              ,CHP.join (,) (reader joinP) (reader joinQ) output
              ]


-- | The type that is an instance of 'Arrow' for process pipelines.  See 'runPipeline'.
data ProcessPipeline a b = ProcessPipeline
  { runPipeline :: Chanin a -> Chanout b -> CHP ()
    -- ^ Given a 'ProcessPipeline' (formed using its 'Arrow' instance) and
    -- the channels to plug into the ends of the pipeline, returns the process
    -- representing the pipeline.
    --
    -- The pipeline will run forever (until poisoned) and you must run it in
    -- parallel to whatever is feeding it the inputs and reading off the outputs.
    --  Imagine that you want a process pipeline that takes in a pair of numbers,
    -- doubles the first and adds one to the second.  You could encode this
    -- in an arrow using:
    -- 
    -- > runPipeline (arr (*2) *** arr (+1))
    --
    -- Arrows are more useful where you already have processes written that
    -- process data and you want to easily wire them together.  The arrow notation
    -- is probably easier for doing that than declaring all the channels yourself
    -- and composing everything in parallel.
  }

-- | Adds a wrapper that forms this process into the right data type to be
-- part of an arrow.
--
-- Any process you apply this to should produce exactly one output per
-- input, or else you will find odd behaviour resulting (including deadlock).
--  So for example, /don't/ use @arrowProcess ('Control.Concurrent.CHP.Common.filter'
-- ...)@ or @arrowProcess 'Control.Concurrent.CHP.Common.stream'@ inside any arrow combinators
-- other than >>> and <<<.
arrowProcess :: (Chanin a -> Chanout b -> CHP ()) -> ProcessPipeline a b
arrowProcess = ProcessPipeline

-- | Like the arr function of the ProcessPipeline arrow instance, but fully evaluates
-- the result before sending it.  If you are building process pipelines with arrows to
-- try and get some parallel speed-up, you should try this function instead of
-- arr itself.
arrStrict :: NFData b => (a -> b) -> ProcessPipeline a b
arrStrict = ProcessPipeline . CHP.map'

instance Functor (ProcessPipeline a) where
  fmap f x = x >>> arr f

instance Category ProcessPipeline where
  (ProcessPipeline q) . (ProcessPipeline p) = ProcessPipeline (p <=> q)
  id = ProcessPipeline CHP.id

instance Arrow ProcessPipeline where
  arr = ProcessPipeline . CHP.map

  first (ProcessPipeline p) = ProcessPipeline $ \in_ out -> do
    c <- newChannel
    c' <- newChannel
    d <- newChannel
    runParallel_
      [ CHP.split in_ (writer c) (writer d)
      , p (reader c) (writer c')
      , CHP.join (,) (reader c') (reader d) out
      ]

  second (ProcessPipeline p) = ProcessPipeline $ \in_ out -> do
    c <- newChannel
    c' <- newChannel
    d <- newChannel
    runParallel_
      [ CHP.split in_ (writer d) (writer c)
      , p (reader c) (writer c')
      , CHP.join (,) (reader d) (reader c') out
      ]

  (ProcessPipeline p) *** (ProcessPipeline q) = ProcessPipeline $ \in_ out -> do
    c <- newChannel
    c' <- newChannel
    d <- newChannel
    d' <- newChannel
    runParallel_
      [ CHP.split in_ (writer c) (writer d)
      , p (reader c) (writer c')
      , q (reader d) (writer d')
      , CHP.join (,) (reader c') (reader d') out
      ]

  (ProcessPipeline p) &&& (ProcessPipeline q) = ProcessPipeline $ \in_ out -> do
    c <- newChannel
    c' <- newChannel
    d <- newChannel
    d' <- newChannel
    runParallel_
      [ CHP.parDelta in_ [writer c, writer d]
      , p (reader c) (writer c')
      , q (reader d) (writer d')
      , CHP.join (,) (reader c') (reader d') out
      ]

instance ArrowChoice ProcessPipeline where
  left (ProcessPipeline p) = ProcessPipeline $ \in_ out -> do
    c <- oneToOneChannel
    d <- oneToOneChannel
    (forever $ do x <- readChannel in_
                  case x of
                    Left l -> do writeChannel (writer c) l
                                 l' <- readChannel (reader d)
                                 writeChannel out (Left l')
                    Right r -> writeChannel out (Right r)
     ) <|*|> p (reader c) (writer d)
    return ()

  right (ProcessPipeline p) = ProcessPipeline $ \in_ out -> do
    c <- oneToOneChannel
    d <- oneToOneChannel
    (forever $ do x <- readChannel in_
                  case x of
                    Right r -> do writeChannel (writer c) r
                                  r' <- readChannel (reader d)
                                  writeChannel out (Right r')
                    Left l -> writeChannel out (Left l)
     ) <|*|> p (reader c) (writer d)
    return ()

  (ProcessPipeline p) ||| (ProcessPipeline q)
    = ProcessPipeline $ \in_ out -> do
        c <- oneToOneChannel
        c' <- oneToOneChannel
        d <- oneToOneChannel
        d' <- oneToOneChannel
        runParallel_
          [ forever $ do x <- readChannel in_
                         x' <- case x of
                                 Left l -> do writeChannel (writer c) l
                                              readChannel (reader c')
                                 Right r -> do writeChannel (writer d) r
                                               readChannel (reader d')
                         writeChannel out x'
          , p (reader c) (writer c')
          , q (reader d) (writer d')
          ]

  (ProcessPipeline p) +++ (ProcessPipeline q)
    = ProcessPipeline $ \in_ out -> do
        c <- oneToOneChannel
        c' <- oneToOneChannel
        d <- oneToOneChannel
        d' <- oneToOneChannel
        runParallel_
          [ forever $ do x <- readChannel in_
                         x' <- case x of
                                 Left l -> do writeChannel (writer c) l
                                              l' <- readChannel (reader c')
                                              return (Left l')
                                 Right r -> do writeChannel (writer d) r
                                               r' <- readChannel (reader d')
                                               return (Right r')
                         writeChannel out x'
          , p (reader c) (writer c')
          , q (reader d) (writer d')
          ]
