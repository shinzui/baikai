-- | Provider-native filesystem layouts for local agent assets.
--
-- Baikai only describes where providers discover assets. Callers own
-- cloning, copying, updating, status reporting, and uninstalling kit
-- content.
module Baikai.AgentAssets
  ( AgentAssetProvider
  , AgentAssetScope
  , AgentAssetKind (..)
  , AgentAssetFormat (..)
  , AgentAssetLayout (..)
  , CodexCustomAgent (..)
  , skillAsset
  , customAgentAsset
  , agentAssetLayout
  , skillTargetPath
  , agentTargetPath
  , agentAssetFormat
  , codexCustomAgentToml
  ) where

import Baikai.Interactive
  ( InteractiveProvider (..)
  , InteractiveScope (..)
  )
import Baikai.Prelude
import Data.Text qualified as Text

-- | Asset helpers use the same provider vocabulary as interactive
-- launchers: Claude Code and Codex are the local provider families.
type AgentAssetProvider = InteractiveProvider

-- | User scope means a home-directory discovery path. Project scope
-- means a path relative to the working project.
type AgentAssetScope = InteractiveScope

data AgentAssetKind
  = SkillAsset
  | CustomAgentAsset
  deriving stock (Eq, Ord, Show, Generic)

data AgentAssetFormat
  = DirectoryAsset
  | MarkdownFile
  | TomlFile
  deriving stock (Eq, Ord, Show, Generic)

data AgentAssetLayout = AgentAssetLayout
  { provider :: !AgentAssetProvider
  , scope :: !AgentAssetScope
  , kind :: !AgentAssetKind
  , format :: !AgentAssetFormat
  , path :: !FilePath
  }
  deriving stock (Eq, Show, Generic)

data CodexCustomAgent = CodexCustomAgent
  { name :: !Text
  , description :: !Text
  , developerInstructions :: !Text
  }
  deriving stock (Eq, Show, Generic)

skillAsset
  :: AgentAssetProvider -> AgentAssetScope -> FilePath -> AgentAssetLayout
skillAsset provider scope name =
  agentAssetLayout provider scope SkillAsset name

customAgentAsset
  :: AgentAssetProvider -> AgentAssetScope -> FilePath -> AgentAssetLayout
customAgentAsset provider scope name =
  agentAssetLayout provider scope CustomAgentAsset name

agentAssetLayout
  :: AgentAssetProvider
  -> AgentAssetScope
  -> AgentAssetKind
  -> FilePath
  -> AgentAssetLayout
agentAssetLayout provider scope kind name =
  AgentAssetLayout
    { provider
    , scope
    , kind
    , format = agentAssetFormat provider kind
    , path = case kind of
        SkillAsset -> skillTargetPath provider scope name
        CustomAgentAsset -> agentTargetPath provider scope name
    }

skillTargetPath :: AgentAssetProvider -> AgentAssetScope -> FilePath -> FilePath
skillTargetPath InteractiveClaude InteractiveProjectScope name =
  joinPath [".claude", "skills", name]
skillTargetPath InteractiveClaude InteractiveUserScope name =
  joinPath ["$HOME", ".claude", "skills", name]
skillTargetPath InteractiveCodex InteractiveProjectScope name =
  joinPath [".agents", "skills", name]
skillTargetPath InteractiveCodex InteractiveUserScope name =
  joinPath ["$HOME", ".agents", "skills", name]

agentTargetPath :: AgentAssetProvider -> AgentAssetScope -> FilePath -> FilePath
agentTargetPath InteractiveClaude InteractiveProjectScope name =
  joinPath [".claude", "agents", name <> ".md"]
agentTargetPath InteractiveClaude InteractiveUserScope name =
  joinPath ["$HOME", ".claude", "agents", name <> ".md"]
agentTargetPath InteractiveCodex InteractiveProjectScope name =
  joinPath [".codex", "agents", name <> ".toml"]
agentTargetPath InteractiveCodex InteractiveUserScope name =
  joinPath ["$HOME", ".codex", "agents", name <> ".toml"]

agentAssetFormat :: AgentAssetProvider -> AgentAssetKind -> AgentAssetFormat
agentAssetFormat _ SkillAsset = DirectoryAsset
agentAssetFormat InteractiveClaude CustomAgentAsset = MarkdownFile
agentAssetFormat InteractiveCodex CustomAgentAsset = TomlFile

-- | Render the minimal TOML shape Codex custom agents expect.
codexCustomAgentToml :: CodexCustomAgent -> Text
codexCustomAgentToml agent =
  Text.unlines
    [ "name = " <> tomlString (agent ^. #name)
    , "description = " <> tomlString (agent ^. #description)
    , "developer_instructions = " <> tomlMultilineString (agent ^. #developerInstructions)
    ]

joinPath :: [FilePath] -> FilePath
joinPath [] = ""
joinPath (first : rest) = foldl' appendSegment first rest
  where
    appendSegment acc segment = acc <> "/" <> segment

tomlString :: Text -> Text
tomlString t =
  "\"" <> Text.concatMap escape t <> "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape c = Text.singleton c

tomlMultilineString :: Text -> Text
tomlMultilineString t =
  "\"\"\"\n" <> Text.replace "\"\"\"" "\\\"\\\"\\\"" t <> "\n\"\"\""
