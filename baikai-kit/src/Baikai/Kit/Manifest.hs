module Baikai.Kit.Manifest
  ( AgentEntry (..),
    KitItem (..),
    KitItemKind (..),
    KitManifest (..),
    SkillEntry (..),
    agentSources,
    itemKind,
    itemName,
    itemVersion,
    kitItemKind,
    kindLabel,
  )
where

import Baikai.Prelude
import Data.Text qualified as Text
import System.FilePath (takeFileName, (</>))

data KitManifest = KitManifest
  { version :: !Int,
    skills :: ![SkillEntry],
    agents :: ![AgentEntry]
  }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON)

data SkillEntry = SkillEntry
  { name :: !Text,
    description :: !Text,
    version :: !(Maybe Text),
    path :: !Text,
    files :: ![Text]
  }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON)

data AgentEntry = AgentEntry
  { name :: !Text,
    description :: !Text,
    version :: !(Maybe Text),
    path :: !Text,
    files :: !(Maybe [Text])
  }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON)

data KitItem
  = KitSkillItem !SkillEntry
  | KitAgentItem !AgentEntry
  deriving stock (Generic, Show)

data KitItemKind
  = SkillKind
  | AgentKind
  deriving stock (Eq, Ord, Show)

agentSources :: AgentEntry -> [(FilePath, FilePath)]
agentSources entry =
  case entry ^. #files of
    Just fs -> [(Text.unpack (entry ^. #path) </> Text.unpack f, Text.unpack f) | f <- fs]
    Nothing ->
      let source = Text.unpack (entry ^. #path)
       in [(source, takeFileName source)]

itemName :: KitItem -> Text
itemName (KitSkillItem entry) = entry ^. #name
itemName (KitAgentItem entry) = entry ^. #name

itemKind :: KitItem -> Text
itemKind KitSkillItem {} = "skill"
itemKind KitAgentItem {} = "agent"

kitItemKind :: KitItem -> KitItemKind
kitItemKind KitSkillItem {} = SkillKind
kitItemKind KitAgentItem {} = AgentKind

kindLabel :: KitItemKind -> Text
kindLabel SkillKind = "skill"
kindLabel AgentKind = "agent"

itemVersion :: KitItem -> Maybe Text
itemVersion (KitSkillItem entry) = entry ^. #version
itemVersion (KitAgentItem entry) = entry ^. #version
