{-# LANGUAGE CPP #-}

module CliCancellationSpec (tests) where

import Baikai
import Baikai.Provider.OpenAI.Cli qualified as Cli
import CliProcessFixture
import Control.Lens ((&), (.~), (^.))
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Streamly.Data.Stream qualified as Stream
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
#ifndef mingw32_HOST_OS
tests = testGroup "CliCancellationSpec: Codex owned batch cancellation"
  [ testCase "simple descendant" $ run False False False,
    testCase "SIGKILL-resistant descendant" $ run True False False,
    testCase "repeated cancellation" $ run True True False,
    testCase "active synthetic stream" $ run False False True,
    testCase "schema lives until cleanup, then is removed" $
      withFixture False False schemaPrefix $ \fixture -> do
        let provider = makeProvider fixture
            opts = emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "fixture" (Aeson.object [])))
        cancelAndJoin False ((provider ^. #complete) model emptyContext opts) fixture $ \pids -> do
          assertStopped pids
          path <- init <$> readFile (directory fixture </> "schema")
          doesFileExist path >>= (@?= False)
          readFile (directory fixture </> "schema-at-termination") >>= (@?= "present\n"),
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
    makeProvider fixture = Cli.codexCliProvider (Cli.defaultCodexCliConfig & #executable .~ executable fixture & #workingDir .~ Just (directory fixture))
    model = emptyModel & #api .~ OpenAICompletionsCli & #modelId .~ "fixture"
    schemaPrefix = "while [ \"$#\" -gt 0 ]; do if [ \"$1\" = \"--output-schema\" ]; then schema=\"$2\"; echo \"$schema\" > schema; test -f \"$schema\" || exit 7; fi; shift; done\ntrap 'test -f \"$schema\" && echo present > schema-at-termination; exit 0' INT TERM"
    versionPrefix = "if [ \"$1\" != \"--version\" ]; then printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"ok\"}}'; exit 0; fi"
#else
tests = testGroup "CliCancellationSpec: POSIX fixtures require Darwin/Linux" []
#endif
