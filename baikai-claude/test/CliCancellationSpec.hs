{-# LANGUAGE CPP #-}

module CliCancellationSpec (tests) where

import Baikai
import Baikai.Provider.Claude.Cli qualified as Cli
import CliProcessFixture
import Control.Lens ((&), (.~), (^.))
import Control.Monad (void)
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)

tests :: TestTree
#ifndef mingw32_HOST_OS
tests = testGroup "CliCancellationSpec: Claude owned batch cancellation"
  [ testCase "simple descendant" $ run False False False,
    testCase "SIGKILL-resistant descendant" $ run True False False,
    testCase "repeated cancellation" $ run True True False,
    testCase "active synthetic stream" $ run False False True,
    testCase "evidence version-probe descendant" $ withFixture False False versionPrefix $ \fixture -> do
      let provider = makeProvider fixture
          opts = emptyOptions & #evidence .~ Just (evidenceRequest "cancellation-probe")
      cancelAndJoin False ((provider ^. #complete) model emptyContext opts) fixture assertStopped
  ]
  where
    run resistant repeated streaming = withFixture resistant False "" $ \fixture -> do
      let provider = makeProvider fixture
          action | streaming = void (Stream.toList ((provider ^. #stream) model emptyContext emptyOptions))
                 | otherwise = void ((provider ^. #complete) model emptyContext emptyOptions)
      cancelAndJoin repeated action fixture assertStopped
    makeProvider fixture = Cli.claudeCliProvider (Cli.defaultClaudeCliConfig & #executable .~ executable fixture)
    model = emptyModel & #api .~ AnthropicMessagesCli & #modelId .~ "fixture"
    versionPrefix = "if [ \"$1\" != \"--version\" ]; then printf '%s\\n' '{\"type\":\"result\",\"result\":\"ok\",\"is_error\":false}'; exit 0; fi"
#else
tests = testGroup "CliCancellationSpec: POSIX fixtures require Darwin/Linux" []
#endif
