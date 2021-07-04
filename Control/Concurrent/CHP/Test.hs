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

-- | A module containing some useful functions for testing CHP programs, both in
-- the QuickCheck 2 framework and using HUnit.
module Control.Concurrent.CHP.Test (QuickCheckCHP, qcCHP, qcCHP', propCHPInOut, testCHP, testCHPInOut,
  testCHP', CHPTestResult(..), (=*=), CHPTest, withCheck, assertCHP, assertCHP',
    assertCHPEqual, assertCHPEqual') where

import Control.Arrow (first, second)
import Control.Monad
import Data.Monoid
import Data.Unique
import Test.HUnit (assertFailure, Test(..))
import Test.QuickCheck (Gen, forAll)
import Test.QuickCheck.Property (Property, Result(..), Testable(..), result, succeeded, ioProperty)
import Text.PrettyPrint.HughesPJ (Doc)

import Control.Concurrent.CHP
import Control.Concurrent.CHP.Traces

-- | A wrapper around the CHP type that supports some QuickCheck 'Testable' instances.
--  See 'qcCHP' and 'qcCHP''.
newtype QuickCheckCHP a = QCCHP (IO (Maybe a, Doc))

-- | Turns a CHP program into a 'QuickCheckCHP' for use with 'Testable' instances.
--
-- Equivalent to @qcCHP' . runCHP_CSPTrace@.
qcCHP :: CHP a -> QuickCheckCHP a
qcCHP = qcCHP' . runCHP_CSPTrace

-- | Takes the command that runs a CHP program and gives back a 'QuickCheckCHP'
-- item for use with 'Testable' instances.
--
-- You use this function like:
--
-- > qcCHP' (runCHP_CSPTrace p)
--
-- To test process @p@ with a CSP trace if it fails.  To turn off the display of
-- tracing when a test fails, use:
--
-- > qcCHP' (runCHP_TraceOff p)
qcCHP' :: Trace t => IO (Maybe a, t Unique) -> QuickCheckCHP a
qcCHP' = QCCHP . liftM (second prettyPrint)

qcResult :: IO (Maybe Result, Doc) -> Property
qcResult m = ioProperty $
             do (mr, t) <- m
                case mr of
                  Just r -> return $ r { reason = reason r ++ "; trace: " ++ show t }
                  Nothing -> return $ result { ok = Just False, reason = "QuickCheckCHP Failure (deadlock/uncaught poison); trace: " ++ show t }

chpToQC :: CHPTestResult -> Result
chpToQC (CHPTestPass) = succeeded
chpToQC (CHPTestFail msg) = result { ok = Just False, reason = msg }

boolToResult :: Bool -> Result
boolToResult b = if b then succeeded else result { ok = Just False }

instance Testable (QuickCheckCHP Bool) where
  property (QCCHP x) = qcResult $ liftM (first $ fmap boolToResult) x

instance Testable (QuickCheckCHP Result) where
  property (QCCHP x) = qcResult x

instance Testable (QuickCheckCHP CHPTestResult) where
  property (QCCHP x) = qcResult $ liftM (first $ fmap chpToQC) x



-- | Tests a process that takes a single input and produces a single output, using
-- QuickCheck.
--
-- The first parameter is a pure function that takes the input to the process,
-- the output the process gave back, and indicates whether this is okay (True =
-- test pass, False = test fail).  The second parameter is the process to test,
-- and the third parameter is the thing to use to generate the inputs (passing 'arbitrary'
-- is the simplest thing to do).
--
-- Here are a couple of example uses:
-- 
-- > propCHPInOut (==) Common.id (arbitrary :: Gen Int)
-- 
-- > propCHPInOut (const $ (< 0)) (Common.map (negate . abs)) (arbitrary :: Gen Int)
--
-- The test starts the process afresh each time, and shuts it down after the single
-- output has been produced (by poisoning both its channels).  Any poison from
-- the process being tested after it has produced its output is consequently ignored,
-- but poison instead of producing an output will cause a test failure.
-- If the process does not produce an output or poison (for example if you test
-- something like the Common.filter process), the test will deadlock.
propCHPInOut :: Show a => (a -> b -> Bool) -> (Chanin a -> Chanout b -> CHP ()) -> Gen a -> Property
propCHPInOut f p gen
  = forAll gen $ \x -> qcCHP $
              do c <- oneToOneChannel
                 d <- oneToOneChannel
                 (_,r) <- (p (reader c) (writer d)
                            `onPoisonTrap` (poison (reader c) >> poison (writer d)))
                   <||> ((do writeChannel (writer c) x
                             y <- readChannel (reader d)
                             poison (writer c) >> poison (reader d)
                             return $ f x y
                         ) `onPoisonTrap` return False)
                 return r

-- | Takes a CHP program that returns a Bool (True = test passed, False = test
-- failed) and forms it into an HUnit test.
--
-- Note that if the program exits with poison, this is counted as a test failure.
testCHP :: CHP Bool -> Test
testCHP = TestCase . (>>= assertWithTrace) . runCHPAndTrace
  where
    assertWithTrace :: (Maybe Bool, CSPTrace Unique) -> IO ()
    assertWithTrace (Just True, _) = return ()
    assertWithTrace (Just False, t) = assertFailure $ "testCHP Failure; trace: " ++ show (prettyPrint t)
    assertWithTrace (Nothing, t) = assertFailure $ "testCHP Failure (deadlock/uncaught poison); trace: " ++ show (prettyPrint t)

-- | A helper type for describing a more detailed result of a CHP test.  You can
-- construct these values manually, or using the '(=*=)' operator.
data CHPTestResult = CHPTestPass | CHPTestFail String

instance Monoid CHPTestResult where
  mempty = CHPTestPass
  mappend CHPTestPass y = y
  mappend x _ = x

-- | Checks if two things are equal; passes the test if they are, otherwise fails
-- and gives an error that shows the two things in question.
(=*=) :: (Eq a, Show a) => a -> a -> CHPTestResult
(=*=) expected act
  | expected == act = CHPTestPass
  | otherwise = CHPTestFail $ "Expected: " ++ show expected ++ "; Actual: " ++ show act

-- | Like 'testCHP' but allows you to return the more descriptive 'CHPTestResult'
-- type, rather than a plain Bool.
testCHP' :: CHP CHPTestResult -> Test
testCHP' p = TestCase $ do (r, t) <- runCHP_CSPTrace p
                           case r of
                             Just CHPTestPass -> return ()
                             Just (CHPTestFail s) -> assertFailure $
                               s ++ "; trace: " ++ show t
                             Nothing -> assertFailure $ "testCHP' Failure (deadlock/uncaught poison); trace: "
                               ++ show t

-- | See withCheck.
newtype CHPTest a = CHPTest {runCHPTest :: CHP (Either String a)}

instance Monad CHPTest where
  return = CHPTest . return . Right
  m >>= k = CHPTest $ runCHPTest m >>= either (return . Left) (runCHPTest . k)

instance MonadCHP CHPTest where
  liftCHP = CHPTest . liftM Right

-- | A helper function that allows you to create CHP tests in an assertion style, either
-- for use with HUnit or QuickCheck 2.
--
-- Any poison thrown by the first argument (the left-hand side when this function
-- is used infix) is trapped and ignored.  Poison thrown by the second argument
-- (the right-hand side when used infix) is counted as a test failure.
--
-- As an example, imagine that you have a process that should repeatedly
-- output the same value (42), called @myProc@.  There are several ways to test
-- this, but for the purposes of illustration we will start by testing the
-- first two values:
--
-- > myTest :: Test
-- > myTest = testCHP' $ do
-- >   c <- oneToOneChannel
-- >   myProc (writer c)
-- >     `withCheck` do x0 <- liftCHP $ readChannel (reader c)
-- >                    assertCHPEqual (poison (reader c)) "First value" 42 x0
-- >                    x1 <- liftCHP $ readChannel (reader c)
-- >                    poison (reader c) -- Shutdown myProc
-- >                    assertCHPEqual' "Second value" 42 x1
--
-- This demonstrates the typical pattern: a do block with some initialisation to
-- begin with (creating channels, enrolling on barriers), then a withCheck call
-- with the thing you want to test on the left-hand side, and the part doing the
-- testing with the asserts on the right-hand side.  Most CHP actions must be surrounded
-- by 'liftCHP', and assertions can then be made about the values.
--
-- Poison is used twice in our example.  The assertCHPEqual function takes as a
-- first argument the command to execute if the assertion fails.  The problem
-- is that if the assertion fails, the right-hand side will finish.  But it is
-- composed in parallel with the left-hand side, which does not know to finish
-- (deadlock!).  Thus we must pass a command to execute if the assertion fails
-- that will shutdown the right-hand side.  The second assertion doesn't need
-- this, because by the time we make the assertion, we have already inserted
-- the poison.  Don't forget that you must poison to shut down the left-hand
-- side if your test is successful or else you will again get deadlock.
--
-- A better way to test this process is of course to read in a much larger number
-- of samples and check they are all the same, for example:
--
-- > myTest :: Test
-- > myTest = testCHP' $ do
-- >   c <- oneToOneChannel
-- >   myProc (writer c)
-- >     `withCheck` do xs <- liftCHP $ replicateM 1000 $ readChannel (reader c)
-- >                    poison (reader c) -- Shutdown myProc
-- >                    assertCHPEqual' "1000 values" xs (replicate 1000 42)
withCheck :: CHP a -> CHPTest () -> CHP CHPTestResult
withCheck p t = liftM snd $ (p `onPoisonTrap` return undefined) <||> do
  er <- runCHPTest t
  case er of
    Left msg -> return $ CHPTestFail msg
    Right _ -> return CHPTestPass

-- | Checks that the given Bool is True.  If it is, the assertion passes and the
-- test continues.  If it is False, the given command is run (which should shut
-- down the left-hand side of withCheck) and the test finishes, failing with the
-- given String.
assertCHP :: CHP () -> String -> Bool -> CHPTest ()
assertCHP comp msg passed
  | passed = return ()
  | otherwise = liftCHP comp >> CHPTest (return $ Left msg)

-- | Checks that the given values are equal (first is the expected value of the
-- test, second is the actual value).  If they are equal, the assertion passes and the
-- test continues.  If they are not equal, the given command is run (which should shut
-- down the left-hand side of withCheck) and the test finishes, failing with the
-- a message formed of the given String, and describing the two values.
assertCHPEqual :: (Eq a, Show a) => CHP () -> String -> a -> a -> CHPTest ()
assertCHPEqual comp msg expected act
  = assertCHP comp
              (msg ++ "; expected: " ++ show expected ++ "; actual: " ++ show act)
              (expected == act)

-- | Like 'assertCHP' but issues no shutdown command.  You should only use this
-- function if you are sure that the left-hand side of withCheck has already completed.
assertCHP' :: String -> Bool -> CHPTest ()
assertCHP' = assertCHP (return ())

-- | Like 'assertCHPEqual' but issues no shutdown command.  You should only use this
-- function if you are sure that the left-hand side of withCheck has already completed.
assertCHPEqual' :: (Eq a, Show a) => String -> a -> a -> CHPTest ()
assertCHPEqual' = assertCHPEqual (return ())

-- | Tests a process that takes a single input and produces a single output, using
-- HUnit.
--
-- The first parameter is a pure function that takes the input to the process,
-- the output the process gave back, and indicates whether this is okay (True =
-- test pass, False = test fail).  The second parameter is the process to test,
-- and the third parameter is the input to send to the process.
--
-- The intention is that you will either create several tests with the same first
-- two parameters or use a const function as the first parameter.  So for example,
-- here is how you might test the identity process with several tests:
-- 
-- > let check = testCHPInOut (==) Common.id
-- > in TestList [check 0, check 3, check undefined]
--
-- Whereas here is how you could test a slightly different process:
--
-- > let check = testCHPInOut (const $ (< 0)) (Common.map (negate . abs))
-- > in TestList $ map check [-5..5]
--
-- The test starts the process afresh each time, and shuts it down after the single
-- output has been produced (by poisoning both its channels).  Any poison from
-- the process being tested after it has produced its output is consequently ignored,
-- but poison instead of producing an output will cause a test failure.
-- If the process does not produce an output or poison (for example if you test
-- something like the Common.filter process), the test will deadlock.
testCHPInOut :: (a -> b -> Bool) -> (Chanin a -> Chanout b -> CHP ()) -> a -> Test
testCHPInOut f p x
  = testCHP $ do c <- oneToOneChannel
                 d <- oneToOneChannel
                 liftM snd $ (p (reader c) (writer d)
                            `onPoisonTrap` (poison (reader c) >> poison (writer d)))
                   <||> ((do writeChannel (writer c) x
                             y <- readChannel (reader d)
                             poison (writer c) >> poison (reader d)
                             return $ f x y
                         ) `onPoisonTrap` return False)


