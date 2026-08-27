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
      codexTomlTest,
      codexTomlLiteralBodyTests
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
  testCase "Codex custom-agent TOML uses a literal body and escapes basic strings" $ do
    codexCustomAgentToml
      CodexCustomAgent
        { name = "repo\"reviewer",
          description = "Reviews\tchanges",
          developerInstructions = "Read first.\nAvoid triple quotes: \"\"\""
        }
      @?= Text.unlines
        [ "name = \"repo\\\"reviewer\"",
          "description = \"Reviews\\tchanges\"",
          -- A literal string interprets nothing, so the three quotation
          -- marks in the body need no escape at all; only three
          -- apostrophes would, and there are none.
          "developer_instructions = \'\'\'\nRead first.\nAvoid triple quotes: \"\"\"\n\'\'\'"
        ]

-- | The body of a Codex custom agent is Markdown a human reads in
-- @.codex\/agents\/*.toml@, so it is rendered as a TOML /literal/
-- multi-line string — delimited by three apostrophes, interpreting
-- nothing — and comes back byte for byte.
--
-- This is the defect these cases exist for: rendered as a /basic/
-- string, every backslash in the body is the start of an escape
-- sequence, so a body containing @\\d+@ made Codex refuse to load the
-- file with an unknown-escape error.
--
-- A literal string cannot contain three apostrophes, a bare carriage
-- return, or any control character other than tab and newline, so such a
-- body falls back to a fully escaped basic string rather than being
-- refused.
codexTomlLiteralBodyTests :: TestTree
codexTomlLiteralBodyTests =
  testGroup
    "Codex custom-agent bodies"
    [ testCase "backslashes render verbatim in a literal string" $
        bodyBlock "Match \\d+ then \\ and stop."
          @?= "developer_instructions = \'\'\'\nMatch \\d+ then \\ and stop.\n\'\'\'",
      testCase "a body containing three apostrophes falls back to a basic string" $
        bodyBlock "say \'\'\'hi\'\'\'"
          @?= "developer_instructions = \"\"\"\nsay \'\'\'hi\'\'\'\n\"\"\"",
      testCase "the fallback escapes backslashes and quotation marks" $
        bodyBlock "a\\b \"c\" \'\'\'"
          @?= "developer_instructions = \"\"\"\na\\\\b \\\"c\\\" \'\'\'\n\"\"\"",
      testCase "a control character in the body forces the fallback and is escaped" $
        bodyBlock "before\SOHafter"
          @?= "developer_instructions = \"\"\"\nbefore\\u0001after\n\"\"\"",
      testCase "newlines survive the fallback as newlines" $
        bodyBlock "first\nsecond\SOH"
          @?= "developer_instructions = \"\"\"\nfirst\nsecond\\u0001\n\"\"\"",
      testCase "control characters in name and description are escaped" $ do
        let rendered =
              Text.lines
                ( codexCustomAgentToml
                    CodexCustomAgent
                      { name = "x\SOHy",
                        description = "\DEL",
                        developerInstructions = "body"
                      }
                )
        take 2 rendered
          @?= [ "name = \"x\\u0001y\"",
                "description = \"\\u007F\""
              ]
    ]
  where
    -- Everything from the third line on: the body's own delimiters and
    -- the lines between them.
    bodyBlock body =
      Text.intercalate
        "\n"
        ( drop
            2
            ( Text.lines
                ( codexCustomAgentToml
                    CodexCustomAgent
                      { name = "n",
                        description = "d",
                        developerInstructions = body
                      }
                )
            )
        )
