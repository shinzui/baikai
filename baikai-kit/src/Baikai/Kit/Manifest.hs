module Baikai.Kit.Manifest
  ( AgentEntry (..),
    ItemSources (..),
    KitItem (..),
    KitItemKind (..),
    KitManifest (..),
    SkillEntry (..),
    itemKind,
    itemName,
    itemSources,
    itemVersion,
    kitItemKind,
    kindLabel,
    supportedManifestVersions,
  )
where

import Baikai.Kit.Error (KitError (..))
import Baikai.Kit.Path (safeItemName, safeRelativePath)
import Baikai.Prelude
import Data.Bifunctor (first)
import System.FilePath (takeDirectory, takeFileName)

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

-- | The manifest versions this installer understands. Both decode
--   identically today; a future version with different semantics must be
--   refused rather than misinstalled.
supportedManifestVersions :: [Int]
supportedManifestVersions = [1, 2]

-- | Where an item's files live inside the kit checkout: a directory
--   relative to the checkout and file names relative to that directory
--   (the first is the agent body for agents).
--
--   Lexically validated; physical checks are
--   'Baikai.Kit.Path.safeSourcePath'.
data ItemSources = ItemSources
  { base :: !FilePath,
    files :: ![FilePath]
  }
  deriving stock (Eq, Generic, Show)

-- | Derive an item's source list. Fails with 'KitUnsafeName',
--   'KitUnsafePath' or 'KitItemHasNoFiles'. The item name is validated
--   here too, so every consumer of the result has already seen it pass.
itemSources :: KitItem -> Either KitError ItemSources
itemSources item = do
  _ <- first (KitUnsafeName (itemName item)) (safeItemName (itemName item))
  case item of
    KitSkillItem entry -> do
      base <- lexPath (entry ^. #path)
      files <- traverse lexPath (entry ^. #files)
      nonEmpty ItemSources {base, files}
    KitAgentItem entry ->
      case entry ^. #files of
        Just declared -> do
          base <- lexPath (entry ^. #path)
          files <- traverse lexPath declared
          nonEmpty ItemSources {base, files}
        Nothing -> do
          source <- lexPath (entry ^. #path)
          pure ItemSources {base = takeDirectory source, files = [takeFileName source]}
  where
    lexPath raw = first (KitUnsafePath raw) (safeRelativePath raw)
    nonEmpty sources
      | null (sources ^. #files) = Left (KitItemHasNoFiles (itemName item))
      | otherwise = Right sources

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
