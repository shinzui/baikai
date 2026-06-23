module Baikai.Kit.Manifest
  ( KitManifest (..),
    SkillEntry (..),
    AgentEntry (..),
    KitItem (..),
    agentSources,
    itemName,
    itemKind,
    itemVersion,
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

itemVersion :: KitItem -> Maybe Text
itemVersion (KitSkillItem entry) = entry ^. #version
itemVersion (KitAgentItem entry) = entry ^. #version
