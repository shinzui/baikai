-- | Visibility is independent of user/project scope.
module Baikai.Kit.Visibility
  ( KitVisibility (..),
    VisibilitySource (..),
    visibilityLabel,
    parseVisibility,
  )
where

import Baikai.Prelude
import Data.Aeson (withText)
import Data.Text qualified as Text

data KitVisibility = ToolOnlyVisibility | SharedVisibility
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data VisibilitySource = FromManifest | FromInstallFlag
  deriving stock (Eq, Show)

visibilityLabel :: KitVisibility -> Text
visibilityLabel ToolOnlyVisibility = "tool-only"
visibilityLabel SharedVisibility = "shared"

parseVisibility :: Text -> Either Text KitVisibility
parseVisibility "tool-only" = Right ToolOnlyVisibility
parseVisibility "shared" = Right SharedVisibility
parseVisibility other = Left ("unknown visibility '" <> other <> "'; expected tool-only or shared")

instance FromJSON KitVisibility where
  parseJSON = withText "KitVisibility" (either (fail . Text.unpack) pure . parseVisibility)
