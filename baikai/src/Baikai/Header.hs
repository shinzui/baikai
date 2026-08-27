-- | HTTP header names as a type that carries the case-insensitivity
-- rule.
--
-- A header name is case-insensitive on the wire, so @Authorization@ and
-- @authorization@ are one header. A @Map Text Text@ of header overrides
-- does not know that: it holds both, and which one reaches the provider
-- is decided by the fold order of whatever code assembles the request.
-- 'HeaderName' puts the rule in the key type, so a @Map HeaderName Text@
-- holds at most one value per header and the last write wins, as a
-- caller writing two spellings would expect.
--
-- The original spelling is preserved and is what goes out on the wire
-- and into JSON, so a host that (wrongly) cares about case still sees
-- what the caller wrote.
--
-- The type is baikai's own rather than a bare
-- 'Data.CaseInsensitive.CI' 'Data.Text.Text' because the aeson
-- instances would then be orphans, which two packages can define
-- incompatibly.
module Baikai.Header
  ( HeaderName,
    headerName,
    renderHeaderName,
  )
where

import Data.Aeson
  ( FromJSON (parseJSON),
    FromJSONKey (fromJSONKey),
    FromJSONKeyFunction (FromJSONKeyText),
    ToJSON (toJSON),
    ToJSONKey (toJSONKey),
    withText,
  )
import Data.Aeson.Types (toJSONKeyText)
import Data.CaseInsensitive (CI)
import Data.CaseInsensitive qualified as CI
import Data.String (IsString (fromString))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

-- | A case-insensitive HTTP header name that remembers its original
-- spelling.
newtype HeaderName = HeaderName (CI Text)
  deriving stock (Eq, Ord, Generic)

-- | Shows the original spelling, so a header map prints as it was
-- written.
instance Show HeaderName where
  showsPrec d = showsPrec d . renderHeaderName

-- | So that @Map.singleton "x-test" "1" :: Map HeaderName Text@ keeps
-- compiling and reading naturally.
instance IsString HeaderName where
  fromString = headerName . Text.pack

instance ToJSON HeaderName where
  toJSON = toJSON . renderHeaderName

instance FromJSON HeaderName where
  parseJSON = withText "HeaderName" (pure . headerName)

instance ToJSONKey HeaderName where
  toJSONKey = toJSONKeyText renderHeaderName

instance FromJSONKey HeaderName where
  fromJSONKey = FromJSONKeyText headerName

-- | A header name from its text. Comparison ignores case from here on;
-- the spelling given is what 'renderHeaderName' returns.
headerName :: Text -> HeaderName
headerName = HeaderName . CI.mk

-- | The name as it was originally written.
renderHeaderName :: HeaderName -> Text
renderHeaderName (HeaderName n) = CI.original n
