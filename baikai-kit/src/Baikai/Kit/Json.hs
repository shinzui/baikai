-- | The machine-readable documents @kit list --json@, @kit status --json@
--   and @kit update --json@ print, as explicit encoders.
--
--   These shapes are a public, versioned contract, pinned by golden tests
--   in @baikai-kit/test/golden/@. They are written here by hand rather
--   than derived, so renaming a Haskell field cannot change them. Every
--   document carries 'kitJsonFormatVersion' and a @document@ name. Adding
--   a key keeps the version; removing or renaming one, or changing what a
--   value means, increments it. Every documented key is always present,
--   with @null@ for an absent value.
--
--   See @docs/adr/0024-machine-readable-kit-output-is-a-versioned-contract.md@.
module Baikai.Kit.Json
  ( kitJsonFormatVersion,
    listDocument,
    statusDocument,
    updateDocument,
  )
where

import Baikai.Kit.Config (KitScope, providerLabel, scopeLabel)
import Baikai.Kit.Error (renderKitError)
import Baikai.Kit.Install (UpdateReport)
import Baikai.Kit.Manifest (KitItemKind (..), KitManifest, kindLabel)
import Baikai.Kit.Repo (RepoRefresh (..))
import Baikai.Kit.Status
  ( InstalledCopy,
    StatusReport,
    StatusRow,
    UpstreamAvailability (..),
    conditionLabel,
  )
import Baikai.Prelude hiding ((.=))
import Data.Aeson (Value (Null), object, (.=))
import Data.List (sortOn)

-- | The @formatVersion@ every document carries.
kitJsonFormatVersion :: Int
kitJsonFormatVersion = 1

-- | @kit-list@: what the kit offers, skills then agents in manifest order,
--   each with the copies installed of it (sorted user before project,
--   then by provider).
listDocument :: UpstreamAvailability -> KitManifest -> [InstalledCopy] -> Value
listDocument availability manifest copies =
  object
    [ "formatVersion" .= kitJsonFormatVersion,
      "document" .= ("kit-list" :: Text),
      "upstream" .= upstreamValue availability,
      "items"
        .= ( [ itemValue SkillKind (entry ^. #name) (entry ^. #description) (entry ^. #version)
             | entry <- manifest ^. #skills
             ]
               ++ [ itemValue AgentKind (entry ^. #name) (entry ^. #description) (entry ^. #version)
                  | entry <- manifest ^. #agents
                  ]
           )
    ]
  where
    itemValue :: KitItemKind -> Text -> Text -> Maybe Text -> Value
    itemValue kind n description version =
      object
        [ "name" .= n,
          "kind" .= kindLabel kind,
          "description" .= description,
          "version" .= version,
          "installed"
            .= map
              copyValue
              ( sortOn
                  (\copy -> (copy ^. #scope, providerLabel (copy ^. #provider)))
                  [copy | copy <- copies, copy ^. #name == n, copy ^. #kind == kind]
              )
        ]
    copyValue :: InstalledCopy -> Value
    copyValue copy =
      object
        [ "scope" .= scopeLabel (copy ^. #scope),
          "provider" .= providerLabel (copy ^. #provider),
          "version" .= (copy ^. #version),
          "path" .= (copy ^. #path)
        ]

-- | @kit-status@: one entry per installed copy — item, scope, and
--   provider — never aggregated, sorted by name, kind, scope, provider.
statusDocument :: StatusReport -> Value
statusDocument report =
  object
    [ "formatVersion" .= kitJsonFormatVersion,
      "document" .= ("kit-status" :: Text),
      "upstream" .= upstreamValue (report ^. #upstream),
      "items" .= map rowValue (sortOn rowKey (report ^. #rows))
    ]
  where
    rowKey row = (row ^. #name, row ^. #kind, row ^. #scope, row ^. #providers)
    rowValue :: StatusRow -> Value
    rowValue row =
      object
        [ "name" .= (row ^. #name),
          "kind" .= (row ^. #kind),
          "scope" .= (row ^. #scope),
          "provider" .= (row ^. #providers),
          "installedVersion" .= (row ^. #installedVersion),
          "latestVersion" .= (row ^. #latestVersion),
          "conditions" .= map conditionLabel (row ^. #conditions),
          "upToDate" .= null (row ^. #conditions)
        ]

-- | @kit-update@: how the cache was refreshed and what was updated or
--   skipped, in the report's order.
updateDocument :: UpdateReport -> Value
updateDocument report =
  object
    [ "formatVersion" .= kitJsonFormatVersion,
      "document" .= ("kit-update" :: Text),
      "refresh" .= fmap refreshLabel (report ^. #refresh),
      "updated" .= map updatedValue (report ^. #updated),
      "skipped" .= map skippedValue (report ^. #skipped)
    ]
  where
    refreshLabel :: RepoRefresh -> Text
    refreshLabel = \case
      RepoCloned -> "cloned"
      RepoPulled -> "pulled"
      RepoStale _ -> "stale"
    updatedValue :: (Text, KitScope) -> Value
    updatedValue (n, scope) = object ["name" .= n, "scope" .= scopeLabel scope]
    -- 'UpdateReport' skips an item only for local edits today; the reason
    -- is spelled out so a later reason is an added value, not a new key.
    skippedValue :: (Text, KitScope) -> Value
    skippedValue (n, scope) =
      object
        [ "name" .= n,
          "scope" .= scopeLabel scope,
          "reason" .= ("locally-modified" :: Text)
        ]

upstreamValue :: UpstreamAvailability -> Value
upstreamValue = \case
  UpstreamReady -> object ["state" .= ("ready" :: Text), "detail" .= Null]
  UpstreamStale detail -> object ["state" .= ("stale" :: Text), "detail" .= detail]
  UpstreamUnavailable err -> object ["state" .= ("unavailable" :: Text), "detail" .= renderKitError err]
