-- | CAP-21, docs/capabilities/kit-installer.md.
module Shape.Cap21 (myKitConfig) where

import Baikai.Interactive (InteractiveProvider (..))
import Baikai.Kit

-- BEGIN CAP-21
myKitConfig :: KitConfig
myKitConfig =
  KitConfig
    { toolName = "mytool",
      repoUrl = "https://github.com/example/mytool-kit.git",
      providers = [InteractiveClaude, InteractiveCodex]
    }

-- END CAP-21
