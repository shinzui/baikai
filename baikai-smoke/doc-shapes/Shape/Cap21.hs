-- | CAP-21, docs/capabilities/kit-installer.md.
module Shape.Cap21 (myKitConfig) where

import Baikai.Interactive (InteractiveProvider (..))
import Baikai.Kit

-- BEGIN CAP-21
myKitConfig :: KitConfig
myKitConfig =
  (kitConfig "mytool" "https://github.com/example/mytool-kit.git" [InteractiveClaude, InteractiveCodex])
    { projectRoot = projectRootByMarkers [".git", ".mytool"]
    }

-- END CAP-21
