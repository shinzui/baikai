-- | The one place baikai reads a host out of a URL.
--
-- baikai decides which API key to send and which per-host compatibility
-- record to apply by looking at the host name inside a model's
-- @baseUrl@. That decision routes a credential, so it has to be made the
-- same way everywhere: two parsers that disagree about what host a URL
-- names are two different answers to "where does this key go".
--
-- This module is deliberately __not__ a validating URI parser. It knows
-- just enough to name a host, key a cache, render an endpoint for an
-- evidence record, and say why a base URL is unusable. It has no
-- dependencies beyond @text@ and @base@, and every function is total.
--
-- The rule, in full:
--
-- * Leading and trailing whitespace is stripped.
--
-- * If the text before the first @\"://\"@ is a syntactically valid
--   scheme — a letter followed by letters, digits, @+@, @-@ or @.@ —
--   that is the scheme, lower-cased, and it is removed. Otherwise there
--   is no scheme and nothing is removed.
--
-- * The __authority__ is everything up to the first @\/@, @?@ or @#@.
--   This is what RFC 3986 means by the term, and bounding it at all
--   three characters is the point of this module: a URL such as
--   @https:\/\/proxy.example.com\/v1?u=\@api.openai.com@ names the host
--   @proxy.example.com@, and anything that reads the text after the last
--   @\@@ anywhere in the URL will send that proxy another host's key.
--
-- * Userinfo is everything up to the last @\@@ __inside the authority__,
--   and is dropped. Its presence is recorded; its text never is.
--
-- * What remains is the host and an optional port. A bracketed IPv6
--   literal keeps its brackets and its port follows the closing
--   bracket; otherwise the host is the text before the first @:@. A
--   non-numeric port is ignored and the host is still the text before
--   the colon. The host is lower-cased, because DNS names are
--   case-insensitive.
--
-- * The path is everything from the first @\/@ up to the first @?@ or
--   @#@, kept verbatim — case and trailing slash included.
--
-- * An empty host means there is no result at all.
module Baikai.Url
  ( -- * Parsing
    UrlParts (scheme, host, port, path, hasUserInfo, hasQuery, hasFragment),
    parseUrl,
    urlHost,
    hostMatchesSuffix,

    -- * Rendering
    renderEndpoint,
    stripApiVersion,

    -- * Fitness as a base URL
    baseUrlProblem,
  )
where

import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

-- | The pieces of a URL that baikai needs.
--
-- Credential-free by construction: userinfo, the query string and the
-- fragment are recorded as /present or absent/ and never as text, so a
-- value of this type cannot carry a secret into a log line. That is why
-- the constructor is not exported — 'parseUrl' is the only producer.
data UrlParts = UrlParts
  { -- | Lower-cased scheme without the @\"://\"@, when one was present.
    scheme :: !(Maybe Text),
    -- | Lower-cased host. An IPv6 literal keeps its brackets: @\"[::1]\"@.
    host :: !Text,
    -- | The port, when one was given as digits.
    port :: !(Maybe Int),
    -- | From the first @\/@ up to (not including) @?@ or @#@; @\"\"@ when
    -- there was no path. Kept verbatim.
    path :: !Text,
    -- | Whether a @user:password\@@ prefix was present and dropped.
    hasUserInfo :: !Bool,
    -- | Whether a @?query@ was present and dropped.
    hasQuery :: !Bool,
    -- | Whether a @#fragment@ was present and dropped.
    hasFragment :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | Parse a URL far enough to name its host. 'Nothing' when no host can
-- be found, which includes the empty string and a bare scheme.
parseUrl :: Text -> Maybe UrlParts
parseUrl raw
  | Text.null hostText = Nothing
  | otherwise =
      Just
        UrlParts
          { scheme = parsedScheme,
            host = hostText,
            port = parsedPort,
            path = pathText,
            hasUserInfo = userInfoPresent,
            hasQuery = queryPresent,
            hasFragment = fragmentPresent
          }
  where
    trimmed = Text.strip raw

    -- The scheme is only a scheme when it looks like one. "note://x" has
    -- one; ":://x" does not, and neither does a bare "api.openai.com".
    (parsedScheme, afterScheme) = case Text.breakOn "://" trimmed of
      (candidate, rest)
        | not (Text.null rest),
          validScheme candidate ->
            (Just (Text.toLower candidate), Text.drop 3 rest)
      _ -> (Nothing, trimmed)
    validScheme s = case Text.uncons s of
      Just (c, cs) -> isAlpha c && Text.all schemeChar cs
      Nothing -> False
    schemeChar c = isAlphaNum c || c == '+' || c == '-' || c == '.'

    -- The authority ends at the first '/', '?' or '#'. Everything this
    -- module exists for depends on that boundary.
    (authority, afterAuthority) =
      Text.break (\c -> c == '/' || c == '?' || c == '#') afterScheme

    -- Userinfo is the last '@' inside the authority, never one later in
    -- the path or query.
    (userInfoPresent, hostAndPort) = case Text.breakOnEnd "@" authority of
      (before, after) | not (Text.null before) -> (True, after)
      _ -> (False, authority)

    (hostText, parsedPort) = splitHostPort hostAndPort

    (pathText, afterPath) =
      Text.break (\c -> c == '?' || c == '#') afterAuthority
    queryPresent = "?" `Text.isPrefixOf` afterPath
    fragmentPresent = "#" `Text.isInfixOf` afterPath

-- | Split @host:port@, keeping an IPv6 literal's brackets together.
splitHostPort :: Text -> (Text, Maybe Int)
splitHostPort raw
  | "[" `Text.isPrefixOf` raw =
      case Text.breakOn "]" raw of
        (literal, rest)
          | not (Text.null rest) ->
              (Text.toLower (literal <> "]"), portOf (Text.drop 1 rest))
        _ -> (Text.toLower raw, Nothing)
  | otherwise =
      let (h, rest) = Text.breakOn ":" raw
       in (Text.toLower h, portOf rest)
  where
    -- ":8080" is a port; ":" alone, ":abc" and "" are not, and in every
    -- one of those cases the host is still what came before the colon.
    portOf rest = case Text.stripPrefix ":" rest of
      Just digits
        | not (Text.null digits),
          Text.all isDigit digits ->
            Just (read (Text.unpack digits))
      _ -> Nothing

-- | The host a URL names, or 'Nothing' when it names none.
urlHost :: Text -> Maybe Text
urlHost = fmap host . parseUrl

-- | Match a hostname against a suffix at a label boundary, so that
-- @evil-api.openai.com.attacker.test@ does not match @api.openai.com@.
hostMatchesSuffix :: Text -> Text -> Bool
hostMatchesSuffix h suffix =
  let lowerHost = Text.toLower (Text.strip h)
      lowerSuffix = Text.toLower (Text.strip suffix)
   in not (Text.null lowerHost)
        && not (Text.null lowerSuffix)
        && (lowerHost == lowerSuffix || ("." <> lowerSuffix) `Text.isSuffixOf` lowerHost)

-- | Render the parts back as an endpoint: scheme, host, port and path,
-- and nothing else. Userinfo, the query and the fragment are gone
-- because 'UrlParts' never held them.
renderEndpoint :: UrlParts -> Text
renderEndpoint parts =
  maybe "" (<> "://") (scheme parts)
    <> host parts
    <> maybe "" (\p -> ":" <> Text.pack (show p)) (port parts)
    <> path parts

-- | Remove one trailing @\/v1@ segment from a path, along with any
-- trailing slashes.
--
-- Segment-wise, so @\/v10@ and @\/v1beta@ are left alone. The result is
-- either @\"\"@ or a path beginning with @\/@. This is what makes
-- @https:\/\/api.deepseek.com\/v1@ — the base URL every OpenAI SDK
-- teaches — compose to one @\/v1\/chat\/completions@ rather than two.
stripApiVersion :: Text -> Text
stripApiVersion raw
  | Text.null trimmed = ""
  | otherwise = case Text.stripSuffix "/v1" withLeadingSlash of
      Just kept -> kept
      Nothing -> withLeadingSlash
  where
    trimmed = Text.dropWhileEnd (== '/') raw
    withLeadingSlash
      | "/" `Text.isPrefixOf` trimmed = trimmed
      | otherwise = "/" <> trimmed

-- | Why this text cannot be used as a model's @baseUrl@, or 'Nothing'
-- when it can.
--
-- Every message names the offending URL with its userinfo and query
-- removed — rendered through 'renderEndpoint', never echoed raw — so an
-- error that reaches a log cannot carry a key someone put in a query
-- parameter.
baseUrlProblem :: Text -> Maybe Text
baseUrlProblem raw = case parseUrl raw of
  Nothing -> Just "no host could be found in it"
  Just parts
    | Nothing <- scheme parts ->
        Just (safe parts <> " has no scheme; start it with https:// or http://")
    | Just s <- scheme parts,
      s /= "http",
      s /= "https" ->
        Just (safe parts <> " uses the scheme " <> s <> "; only http and https are sent")
    | hasUserInfo parts ->
        Just
          ( safe parts
              <> " carries credentials before the host, which are never sent; \
                 \use Options.apiKey for the API key or Options.headers for a \
                 \gateway header"
          )
    | hasQuery parts ->
        Just
          ( safe parts
              <> " has a query string; baikai composes the request path itself \
                 \and does not support per-host query parameters such as \
                 \?api-version=. Remove it, or front the host with a gateway \
                 \that adds it"
          )
    | hasFragment parts ->
        Just (safe parts <> " has a fragment, which is not part of a request")
    | Just ending <- endpointSuffix (path parts) ->
        Just
          ( safe parts
              <> " already ends in the endpoint path "
              <> ending
              <> "; Model.baseUrl is the API root, and baikai appends the \
                 \endpoint path itself"
          )
    | otherwise -> Nothing
  where
    safe = renderEndpoint
    endpointSuffix p =
      case filter (`Text.isSuffixOf` Text.dropWhileEnd (== '/') p) endpointPaths of
        (found : _) -> Just found
        [] -> Nothing
    endpointPaths = ["/chat/completions", "/messages", "/embeddings"]
