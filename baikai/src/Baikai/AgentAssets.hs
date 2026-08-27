-- | Provider-native filesystem layouts for local agent assets.
--
-- Baikai only describes where providers discover assets. Callers own
-- cloning, copying, updating, status reporting, and uninstalling kit
-- content.
module Baikai.AgentAssets
  ( AgentAssetProvider,
    AgentAssetScope,
    AgentAssetKind (..),
    AgentAssetFormat (..),
    AgentAssetLayout (..),
    CodexCustomAgent (..),
    skillAsset,
    customAgentAsset,
    agentAssetLayout,
    skillTargetPath,
    agentTargetPath,
    agentAssetFormat,
    codexCustomAgentToml,
  )
where

import Baikai.Interactive
  ( InteractiveProvider (..),
    InteractiveScope (..),
  )
import Baikai.Prelude
import Data.Text qualified as Text
import Text.Printf (printf)

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
  { provider :: !AgentAssetProvider,
    scope :: !AgentAssetScope,
    kind :: !AgentAssetKind,
    format :: !AgentAssetFormat,
    path :: !FilePath
  }
  deriving stock (Eq, Show, Generic)

data CodexCustomAgent = CodexCustomAgent
  { name :: !Text,
    description :: !Text,
    developerInstructions :: !Text
  }
  deriving stock (Eq, Show, Generic)

skillAsset ::
  AgentAssetProvider -> AgentAssetScope -> FilePath -> AgentAssetLayout
skillAsset provider scope name =
  agentAssetLayout provider scope SkillAsset name

customAgentAsset ::
  AgentAssetProvider -> AgentAssetScope -> FilePath -> AgentAssetLayout
customAgentAsset provider scope name =
  agentAssetLayout provider scope CustomAgentAsset name

agentAssetLayout ::
  AgentAssetProvider ->
  AgentAssetScope ->
  AgentAssetKind ->
  FilePath ->
  AgentAssetLayout
agentAssetLayout provider scope kind name =
  AgentAssetLayout
    { provider,
      scope,
      kind,
      format = agentAssetFormat provider kind,
      path = case kind of
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
    [ "name = " <> tomlString (agent ^. #name),
      "description = " <> tomlString (agent ^. #description),
      "developer_instructions = " <> tomlMultilineString (agent ^. #developerInstructions)
    ]

joinPath :: [FilePath] -> FilePath
joinPath [] = ""
joinPath (first : rest) = foldl' appendSegment first rest
  where
    appendSegment acc segment = acc <> "/" <> segment

-- | A TOML /basic/ string: quotation mark, backslash, and every control
-- character escaped, as TOML 1.0 requires. A basic string interprets
-- backslash escapes, so an unescaped control character in one is a
-- parse error rather than a stray byte.
tomlString :: Text -> Text
tomlString t = "\"" <> Text.concatMap escapeBasic t <> "\""

-- | One character inside a TOML basic string.
--
-- The six named escapes are the ones TOML spells; everything else below
-- U+0020, and U+007F, takes the @\\uXXXX@ form. Nothing above that is
-- escaped: TOML basic strings are Unicode, and escaping more would only
-- make the file harder to read.
escapeBasic :: Char -> Text
escapeBasic = \case
  '"' -> "\\\""
  '\\' -> "\\\\"
  '\b' -> "\\b"
  '\t' -> "\\t"
  '\n' -> "\\n"
  '\f' -> "\\f"
  '\r' -> "\\r"
  c
    | c < ' ' || c == '\DEL' -> Text.pack (printf "\\u%04X" (fromEnum c))
    | otherwise -> Text.singleton c

-- | The instructions body of a Codex custom agent.
--
-- Rendered as a TOML /literal/ multi-line string — three apostrophes,
-- interpreting nothing — so the Markdown a human opens in
-- @.codex\/agents\/*.toml@ is the Markdown that was written, backslashes
-- intact. Rendered as a /basic/ string instead, every backslash in the
-- body starts an escape sequence, so a body containing @\\d+@ made Codex
-- refuse to load the file.
--
-- A literal string cannot contain three apostrophes, a bare carriage
-- return, or any control character other than tab and newline, so such a
-- body falls back to a fully escaped basic string rather than being
-- refused. Escaping every quotation mark there guarantees the closing
-- delimiter cannot appear inside, and escaping every backslash means no
-- line-ending backslash can silently swallow the next line's
-- indentation.
tomlMultilineString :: Text -> Text
tomlMultilineString t
  | literalSafe = "\'\'\'\n" <> t <> "\n\'\'\'"
  | otherwise = "\"\"\"\n" <> Text.concatMap escapeMultiline t <> "\n\"\"\""
  where
    literalSafe = not ("\'\'\'" `Text.isInfixOf` t) && Text.all literalChar t
    literalChar c = c == '\t' || c == '\n' || (c >= ' ' && c /= '\DEL')
    -- A raw newline is allowed inside a multi-line basic string and
    -- keeps the body readable; everything else follows the basic rules.
    escapeMultiline '\n' = "\n"
    escapeMultiline c = escapeBasic c
