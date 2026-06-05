module AgentAssetsSpec (tests) where

import Baikai.AgentAssets
import Baikai.Interactive
import Data.Text qualified as Text
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.AgentAssets"
    [ pathTests,
      layoutTests,
      codexTomlTest
    ]

pathTests :: TestTree
pathTests =
  testGroup
    "target paths"
    [ testCase "Claude Code project paths" $ do
        skillTargetPath InteractiveClaude InteractiveProjectScope "example"
          @?= ".claude/skills/example"
        agentTargetPath InteractiveClaude InteractiveProjectScope "example"
          @?= ".claude/agents/example.md",
      testCase "Claude Code user paths" $ do
        skillTargetPath InteractiveClaude InteractiveUserScope "example"
          @?= "$HOME/.claude/skills/example"
        agentTargetPath InteractiveClaude InteractiveUserScope "example"
          @?= "$HOME/.claude/agents/example.md",
      testCase "Codex project paths use .agents for skills and .codex for agents" $ do
        skillTargetPath InteractiveCodex InteractiveProjectScope "example"
          @?= ".agents/skills/example"
        agentTargetPath InteractiveCodex InteractiveProjectScope "example"
          @?= ".codex/agents/example.toml",
      testCase "Codex user paths use home discovery roots" $ do
        skillTargetPath InteractiveCodex InteractiveUserScope "example"
          @?= "$HOME/.agents/skills/example"
        agentTargetPath InteractiveCodex InteractiveUserScope "example"
          @?= "$HOME/.codex/agents/example.toml"
    ]

layoutTests :: TestTree
layoutTests =
  testGroup
    "layout metadata"
    [ testCase "skills are directory assets" $ do
        agentAssetFormat InteractiveClaude SkillAsset @?= DirectoryAsset
        agentAssetFormat InteractiveCodex SkillAsset @?= DirectoryAsset,
      testCase "custom agents use provider-native file formats" $ do
        agentAssetFormat InteractiveClaude CustomAgentAsset @?= MarkdownFile
        agentAssetFormat InteractiveCodex CustomAgentAsset @?= TomlFile,
      testCase "layout carries provider, scope, kind, format, and path" $ do
        customAgentAsset InteractiveCodex InteractiveProjectScope "reviewer"
          @?= AgentAssetLayout
            { provider = InteractiveCodex,
              scope = InteractiveProjectScope,
              kind = CustomAgentAsset,
              format = TomlFile,
              path = ".codex/agents/reviewer.toml"
            }
    ]

codexTomlTest :: TestTree
codexTomlTest =
  testCase "Codex custom-agent TOML escapes strings and preserves instructions" $ do
    codexCustomAgentToml
      CodexCustomAgent
        { name = "repo\"reviewer",
          description = "Reviews\tchanges",
          developerInstructions = "Read first.\nAvoid triple quotes: \"\"\""
        }
      @?= Text.unlines
        [ "name = \"repo\\\"reviewer\"",
          "description = \"Reviews\\tchanges\"",
          "developer_instructions = \"\"\"\nRead first.\nAvoid triple quotes: \\\"\\\"\\\"\n\"\"\""
        ]
