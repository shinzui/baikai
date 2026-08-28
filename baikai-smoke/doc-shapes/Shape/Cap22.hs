-- | CAP-22, docs/capabilities/agent-asset-layouts.md.
module Shape.Cap22 (layout) where

import Baikai.AgentAssets
import Baikai.Interactive (InteractiveProvider (..), InteractiveScope (..))

-- BEGIN CAP-22
layout :: AgentAssetLayout
layout = skillAsset InteractiveClaude InteractiveProjectScope "reviewer"

-- layout ^. #path is ".claude/skills/reviewer"
-- END CAP-22
