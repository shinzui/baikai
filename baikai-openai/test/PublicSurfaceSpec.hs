{-# LANGUAGE OverloadedRecordDot #-}

-- | A downstream consumer's view of @baikai-openai@, compiled.
--
-- Imports only the four public modules — no @.Internal@, no
-- @Baikai.Prelude@, no lens — and builds everything a consumer builds.
-- The compilation is the test: a name that stops being exported, or a
-- record that can no longer be built without its constructor, fails the
-- build here rather than at a consumer.
module PublicSurfaceSpec (tests) where

import Baikai
import Baikai.Agent (AgentCommand (executable), AgentProvider (AgentCodex), agentRunRequest)
import Baikai.Provider.OpenAI.Agent qualified as Agent
import Baikai.Provider.OpenAI.Api qualified as Api
import Baikai.Provider.OpenAI.Cli qualified as Cli
import Baikai.Provider.OpenAI.Interactive qualified as Interactive
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "public surface (baikai-openai)"
    [ testCase "the provider values carry their API tags" $ do
        Api.openaiChatProvider.apiTag @?= OpenAIChatCompletions
        (Cli.codexCliProvider Cli.defaultCodexCliConfig).apiTag @?= OpenAICompletionsCli,
      testCase "the interactive launcher renders a command without running one" $
        case Interactive.codexInteractiveCommand
          Interactive.defaultCodexInteractiveConfig
          (interactiveLaunchRequest "look around") of
          Left refusal -> assertRefusalIsUnexpected refusal
          Right (executable, _args) -> executable @?= "codex",
      testCase "the unattended renderer renders a command without running one" $
        case Agent.codexAgentCommand
          Agent.defaultCodexAgentConfig
          (agentRunRequest AgentCodex "." "summarise") of
          Left refusal -> assertRefusalIsUnexpected refusal
          Right (cmd, _translation) -> cmd.executable @?= "codex"
    ]
  where
    assertRefusalIsUnexpected refusal =
      fail ("expected a rendered command, got a refusal: " <> show refusal)
