-- | Hermetic tests of the two streaming operations. 'streamCollect' materializes
-- the event list; 'streamEach' runs a caller-supplied 'Eff' callback once per
-- event. The agreement test proves the higher-order interpreter delivers every
-- event, in order, inside 'Eff'.
module StreamSpec (tests) where

import Baikai (AssistantMessageEvent (..), DeltaPayload (..))
import Baikai.Effectful (runBaikaiWith, streamCollect, streamEach)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Effectful (liftIO, runEff)
import StubProvider (stubContext, stubModel, stubOptions, stubRegistry)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | The text the stub provider emits; it surfaces in the stream as a TextDelta.
stubText :: T.Text
stubText = "hello stream"

tests :: TestTree
tests =
  testGroup
    "StreamSpec"
    [ testCase "streamCollect returns event sequence" $ do
        reg <- stubRegistry stubText
        events <-
          runEff . runBaikaiWith reg $
            streamCollect stubModel stubContext stubOptions
        assertBool "non-empty" (not (null events))
        assertBool
          "first event is EventStart"
          (case events of EventStart {} : _ -> True; _ -> False)
        assertBool
          "last event is EventDone"
          (case reverse events of EventDone {} : _ -> True; _ -> False)
        let deltas = [t | TextDelta DeltaPayload {delta = t} <- events]
        T.concat deltas @?= stubText,
      testCase "streamEach observes each event in order" $ do
        reg <- stubRegistry stubText
        ref <- newIORef []
        runEff . runBaikaiWith reg $
          streamEach stubModel stubContext stubOptions $ \e ->
            liftIO (modifyIORef' ref (e :))
        observed <- reverse <$> readIORef ref
        collected <-
          runEff . runBaikaiWith reg $
            streamCollect stubModel stubContext stubOptions
        observed @?= collected
    ]
