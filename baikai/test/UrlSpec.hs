-- | The one URL parser, and the three decisions that hang off it: which
-- API key a base URL resolves, which compatibility record it selects,
-- and what an evidence record calls the endpoint.
--
-- The cases that matter most are the negative ones. baikai routes a
-- credential by host name, so a parser that can be talked into naming
-- the wrong host is a parser that can be talked into sending one
-- provider's key to another.
module UrlSpec (urlTests) where

import Baikai
  ( autoDetectAnthropicMessages,
    autoDetectOpenAICompletions,
    defaultAnthropicMessagesCompat,
    defaultApiKeyEnvForBaseUrl,
    defaultOpenAICompletionsCompat,
  )
import Baikai.Evidence.Build (sanitizeEndpoint)
import Baikai.Http qualified as Http
import Baikai.Url
  ( UrlParts (..),
    baseUrlProblem,
    parseUrl,
    renderEndpoint,
    stripApiVersion,
    urlHost,
  )
import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as Text
import Servant.Client qualified as Client
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

urlTests :: TestTree
urlTests =
  testGroup
    "Baikai.Url"
    [ authorityBoundaryTests,
      hostAndPortTests,
      renderingTests,
      stripApiVersionTests,
      baseUrlProblemTests,
      canonicalBaseUrlTests
    ]

-- --------------------------------------------------------------------
-- Where the authority ends
-- --------------------------------------------------------------------

-- | The defect this module exists for. Reading the text after the last
-- @\@@ anywhere in a URL lets anyone who can set @baseUrl@ choose which
-- provider's key baikai sends — and send it to their own host.
authorityBoundaryTests :: TestTree
authorityBoundaryTests =
  testGroup
    "the authority ends at the first /, ? or #"
    [ testCase "an @ in the query does not rename the host" $ do
        let url = "https://proxy.example.com/v1?u=@api.openai.com"
        urlHost url @?= Just "proxy.example.com"
        -- The consequences, asserted rather than assumed: no key is
        -- resolved for an unknown host, and no vendor compat record is
        -- selected for it either.
        defaultApiKeyEnvForBaseUrl url @?= Nothing
        assertBool
          "no OpenAI compat record for a proxy host"
          (autoDetectOpenAICompletions url == defaultOpenAICompletionsCompat)
        assertBool
          "no vendor Anthropic compat record for a proxy host"
          (autoDetectAnthropicMessages url == defaultAnthropicMessagesCompat),
      testCase "an @ in a query with no path does not rename the host" $
        -- The case the evidence module's own parser got wrong: it
        -- bounded the authority at the first "/" only.
        urlHost "https://proxy.example.com?u=@api.openai.com"
          @?= Just "proxy.example.com",
      testCase "an @ in a fragment does not rename the host" $
        urlHost "https://proxy.example.com#@api.openai.com"
          @?= Just "proxy.example.com",
      testCase "an @ in the path does not rename the host" $ do
        urlHost "https://api.openai.com/v1/@x" @?= Just "api.openai.com"
        defaultApiKeyEnvForBaseUrl "https://api.openai.com/v1/@x"
          @?= Just "OPENAI_API_KEY",
      testCase "real userinfo is still dropped" $ do
        let url = "https://user:pw@api.openai.com/"
        urlHost url @?= Just "api.openai.com"
        fmap hasUserInfo (parseUrl url) @?= Just True
        defaultApiKeyEnvForBaseUrl url @?= Just "OPENAI_API_KEY"
    ]

-- --------------------------------------------------------------------
-- Hosts, ports and paths
-- --------------------------------------------------------------------

hostAndPortTests :: TestTree
hostAndPortTests =
  testGroup
    "hosts, ports and paths"
    [ testCase "an IPv6 literal keeps its brackets and its port" $ do
        parts <- expectParse "http://[::1]:8080/v1"
        host parts @?= "[::1]"
        port parts @?= Just 8080
        path parts @?= "/v1",
      testCase "an IPv6 literal with no port has no port" $ do
        parts <- expectParse "https://[::1]"
        host parts @?= "[::1]"
        port parts @?= Nothing,
      testCase "the host is lower-cased and the path is not" $ do
        parts <- expectParse "https://Api.OpenAI.com:443/V1/"
        host parts @?= "api.openai.com"
        port parts @?= Just 443
        path parts @?= "/V1/",
      testCase "a non-numeric port is ignored and the host survives" $ do
        parts <- expectParse "https://api.openai.com:notaport/v1"
        host parts @?= "api.openai.com"
        port parts @?= Nothing,
      testCase "a scheme-less URL parses with no scheme" $ do
        parts <- expectParse "api.openai.com"
        scheme parts @?= Nothing
        host parts @?= "api.openai.com",
      testCase "a scheme is recognised only when it looks like one" $ do
        parts <- expectParse "HTTPS://Api.OpenAI.com"
        scheme parts @?= Just "https",
      testCase "no host means no result" $ do
        parseUrl "" @?= Nothing
        parseUrl "https://" @?= Nothing
        parseUrl "   " @?= Nothing
    ]

-- --------------------------------------------------------------------
-- Rendering an endpoint
-- --------------------------------------------------------------------

renderingTests :: TestTree
renderingTests =
  testGroup
    "rendering an endpoint"
    [ testCase "userinfo, query and fragment are gone; scheme and host are lower-cased" $ do
        let url = "https://user:pw@Host.example:8443/a/b?k=v#f"
        parts <- expectParse url
        renderEndpoint parts @?= "https://host.example:8443/a/b"
        -- The evidence record's endpoint is the same function, so the
        -- two cannot drift.
        sanitizeEndpoint url @?= Just "https://host.example:8443/a/b",
      testCase "an empty endpoint is absent rather than empty" $
        sanitizeEndpoint "" @?= Nothing
    ]

-- --------------------------------------------------------------------
-- Stripping a version segment
-- --------------------------------------------------------------------

stripApiVersionTests :: TestTree
stripApiVersionTests =
  testGroup
    "stripApiVersion removes one trailing /v1 segment"
    [ testCase "a bare version path becomes empty" $ do
        stripApiVersion "/v1" @?= ""
        stripApiVersion "/v1/" @?= ""
        stripApiVersion "/" @?= ""
        stripApiVersion "" @?= ""
        stripApiVersion "v1" @?= "",
      testCase "a mounted API keeps its prefix" $ do
        stripApiVersion "/api/v1" @?= "/api"
        stripApiVersion "/compatible-mode/v1/" @?= "/compatible-mode"
        stripApiVersion "api" @?= "/api",
      testCase "a segment that merely starts with v1 is untouched" $ do
        stripApiVersion "/v10" @?= "/v10"
        stripApiVersion "/v1beta" @?= "/v1beta"
    ]

-- --------------------------------------------------------------------
-- Fitness as a base URL
-- --------------------------------------------------------------------

baseUrlProblemTests :: TestTree
baseUrlProblemTests =
  testGroup
    "baseUrlProblem"
    [ testCase "the shapes baikai supports are accepted" $ do
        baseUrlProblem "https://api.openai.com" @?= Nothing
        baseUrlProblem "https://api.deepseek.com/v1" @?= Nothing
        baseUrlProblem "https://openrouter.ai/api" @?= Nothing
        baseUrlProblem "http://localhost:11434" @?= Nothing,
      testCase "a query string is refused without echoing it" $ do
        problem <- expectProblem "https://h.example/v1?api-version=1"
        assertBool
          ("names the problem: " <> Text.unpack problem)
          ("query string" `Text.isInfixOf` problem)
        assertBool
          ("does not echo the query: " <> Text.unpack problem)
          (not ("api-version=1" `Text.isInfixOf` problem)),
      testCase "userinfo is refused without echoing the password" $ do
        problem <- expectProblem "https://u:secret@h.example"
        assertBool
          ("names the problem: " <> Text.unpack problem)
          ("credentials" `Text.isInfixOf` problem)
        assertBool
          ("does not echo the password: " <> Text.unpack problem)
          (not ("secret" `Text.isInfixOf` problem)),
      testCase "a missing scheme is refused, saying which to use" $ do
        problem <- expectProblem "h.example"
        assertBool
          ("names the fix: " <> Text.unpack problem)
          ("https://" `Text.isInfixOf` problem),
      testCase "a scheme baikai does not send is refused" $ do
        problem <- expectProblem "ftp://h.example"
        assertBool
          ("names the scheme: " <> Text.unpack problem)
          ("ftp" `Text.isInfixOf` problem),
      testCase "a fragment is refused" $ do
        problem <- expectProblem "https://h.example/v1#frag"
        assertBool
          ("names the problem: " <> Text.unpack problem)
          ("fragment" `Text.isInfixOf` problem),
      testCase "a full endpoint URL is refused as a base URL" $ do
        forM_ ["https://h.example/v1/chat/completions", "https://h.example/v1/messages", "https://h.example/v1/embeddings"] $ \url -> do
          problem <- expectProblem url
          assertBool
            ("names the problem for " <> Text.unpack url <> ": " <> Text.unpack problem)
            ("endpoint path" `Text.isInfixOf` problem),
      testCase "text that names no host is refused" $ do
        problem <- expectProblem ""
        assertBool
          ("names the problem: " <> Text.unpack problem)
          ("no host" `Text.isInfixOf` problem)
    ]

-- --------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------

expectParse :: Text -> IO UrlParts
expectParse url = case parseUrl url of
  Nothing -> assertFailure ("expected " <> Text.unpack url <> " to parse")
  Just parts -> pure parts

expectProblem :: Text -> IO Text
expectProblem url = case baseUrlProblem url of
  Nothing -> assertFailure ("expected " <> Text.unpack url <> " to be refused")
  Just problem -> pure problem

-- --------------------------------------------------------------------
-- What the transports actually connect to
-- --------------------------------------------------------------------

-- | The normalisation the connection cache keys on, and the composition
-- rule the transports rely on.
canonicalBaseUrlTests :: TestTree
canonicalBaseUrlTests =
  testGroup
    "canonicalBaseUrl"
    [ testCase "a trailing /v1 and its absence are the same target" $ do
        withVersion <- expectCanonical "https://api.deepseek.com/v1"
        without <- expectCanonical "https://api.deepseek.com"
        Client.showBaseUrl withVersion @?= Client.showBaseUrl without,
      testCase "the host is lower-cased and a default port is implied" $ do
        base <- expectCanonical "https://Api.OpenAI.com:443/"
        Client.showBaseUrl base @?= "https://api.openai.com",
      testCase "a mounted API keeps its prefix without its version" $ do
        base <- expectCanonical "https://openrouter.ai/api/v1/"
        Client.baseUrlPath base @?= "/api",
      testCase "an unusable base URL is a reason, not an exception" $
        case Http.canonicalBaseUrl "h.test" of
          Right base ->
            assertFailure ("expected a refusal, got " <> Client.showBaseUrl base)
          Left problem ->
            assertBool
              ("names the fix: " <> Text.unpack problem)
              ("https://" `Text.isInfixOf` problem)
    ]

expectCanonical :: Text -> IO Client.BaseUrl
expectCanonical url = case Http.canonicalBaseUrl url of
  Left problem -> assertFailure (Text.unpack (url <> " was refused: " <> problem))
  Right base -> pure base
