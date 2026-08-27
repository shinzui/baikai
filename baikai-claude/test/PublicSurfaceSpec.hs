{-# LANGUAGE OverloadedRecordDot #-}

-- | A downstream consumer's view of @baikai-claude@, compiled.
--
-- Imports only the four public modules — no @.Internal@, no
-- @Baikai.Prelude@, no lens — and builds everything a consumer builds.
-- The compilation is the test: a name that stops being exported, or a
-- record that can no longer be built without its constructor, fails the
-- build here rather than at a consumer.
module PublicSurfaceSpec (tests) where

import Baikai
import Baikai.Agent (AgentCommand (executable), AgentProvider (AgentClaude), agentRunRequest)
import Baikai.Provider.Claude.Agent qualified as Agent
import Baikai.Provider.Claude.Api qualified as Api
import Baikai.Provider.Claude.Cli qualified as Cli
import Baikai.Provider.Claude.Interactive qualified as Interactive
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "public surface (baikai-claude)"
    [ testCase "the provider values carry their API tags" $ do
        Api.claudeMessagesProvider.apiTag @?= AnthropicMessages
        (Cli.claudeCliProvider Cli.defaultClaudeCliConfig).apiTag @?= AnthropicMessagesCli,
      testCase "the interactive launcher renders a command without running one" $
        case Interactive.claudeInteractiveCommand
          Interactive.defaultClaudeInteractiveConfig
          (interactiveLaunchRequest "look around") of
          Left refusal -> assertRefusalIsUnexpected refusal
          Right (executable, _args) -> executable @?= "claude",
      testCase "the unattended renderer renders a command without running one" $
        case Agent.claudeAgentCommand
          Agent.defaultClaudeAgentConfig
          (agentRunRequest AgentClaude "." "summarise") of
          Left refusal -> assertRefusalIsUnexpected refusal
          Right (cmd, _translation) -> cmd.executable @?= "claude"
    ]
  where
    assertRefusalIsUnexpected refusal =
      fail ("expected a rendered command, got a refusal: " <> show refusal)
