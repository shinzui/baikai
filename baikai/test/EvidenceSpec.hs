-- | Tests for "Baikai.Evidence": that the canonical encoding really is
-- canonical, that the two digests differ in exactly the way they are
-- documented to, and that the configuration projection lets no content
-- through.
module EvidenceSpec (tests) where

import Baikai.Evidence
import Data.Aeson (Value (Number, Object, String), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as Text
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Evidence"
    [ canonicalTests,
      digestTests,
      redactionTests,
      observedTests
    ]

-- ============================================================
-- Canonical encoding
-- ============================================================

-- | The same logical object built by inserting keys in two different
-- orders. Built by folding inserts over two differently ordered lists
-- rather than with 'object', because aeson's 'KeyMap' may or may not
-- preserve insertion order depending on its size and build flags, and
-- the test must be meaningful either way.
canonicalTests :: TestTree
canonicalTests =
  testGroup
    "canonical encoding"
    [ testCase "is stable across map insertion order" $ do
        let values = map (Number . fromIntegral) [1 :: Int ..]
            keys = ["zulu", "alpha", "mike", "bravo", "yankee", "charlie"]
            pairs = zip keys values
            forwards = fromPairs pairs
            backwards = fromPairs (reverse pairs)
        canonicalEncode forwards @?= canonicalEncode backwards
        commitmentDigest forwards @?= commitmentDigest backwards,
      testCase "sorts keys ascending and emits no whitespace" $ do
        let v = fromPairs [("b", Number 2), ("a", Number 1)]
        canonicalEncode v @?= BS8.pack "{\"a\":1,\"b\":2}",
      testCase "nested objects are sorted too" $ do
        let inner = fromPairs [("z", Number 1), ("y", Number 2)]
            v = fromPairs [("outer", inner)]
        canonicalEncode v @?= BS8.pack "{\"outer\":{\"y\":2,\"z\":1}}",
      testCase "array order is preserved" $
        canonicalEncode (Aeson.toJSON [3 :: Int, 1, 2])
          @?= BS8.pack "[3,1,2]",
      testCase "normalises integral and fractional number spellings" $ do
        -- Every spelling on the left is the same mathematical value as
        -- the one it is compared against; aeson parses them into
        -- different Scientific values.
        encodeJson "1" @?= "1"
        encodeJson "1.0" @?= "1"
        encodeJson "1.00" @?= "1"
        encodeJson "1e0" @?= "1"
        encodeJson "1e2" @?= "100"
        encodeJson "0.1" @?= "0.1"
        encodeJson "1e-1" @?= "0.1"
        encodeJson "1.100" @?= "1.1"
        encodeJson "-0.50" @?= "-0.5",
      testCase "escapes only what JSON requires" $ do
        canonicalEncode (String "a\"b\\c") @?= BS8.pack "\"a\\\"b\\\\c\""
        canonicalEncode (String "line\nbreak") @?= BS8.pack "\"line\\nbreak\""
        canonicalEncode (String "bell\a") @?= BS8.pack "\"bell\\u0007\""
        -- Non-ASCII travels as UTF-8, not as a \u escape.
        canonicalEncode (String "\28450\23383")
          @?= BS8.pack "\"\230\188\162\229\173\151\""
    ]
  where
    encodeJson :: String -> String
    encodeJson src = case Aeson.decodeStrict (BS8.pack src) of
      Just (v :: Value) -> BS8.unpack (canonicalEncode v)
      Nothing -> "<unparsed: " <> src <> ">"

-- | Build an object by folding inserts in the given order, so that a
-- caller can control insertion history. 'Data.Aeson.object' would not
-- do: the point of the ordering test is that two different insertion
-- histories still encode identically.
fromPairs :: [(Text.Text, Value)] -> Value
fromPairs = Object . foldl' step KeyMap.empty
  where
    step acc (k, v) = KeyMap.insert (Key.fromText k) v acc

-- ============================================================
-- The two digests
-- ============================================================

digestTests :: TestTree
digestTests =
  testGroup
    "digests"
    [ testCase "a digest is sha256: plus 64 lowercase hex characters" $ do
        env <- loadFixture
        let d = commitmentDigest env
        assertBool ("expected a sha256: prefix, got " <> Text.unpack d) $
          "sha256:" `Text.isPrefixOf` d
        Text.length (Text.drop 7 d) @?= 64
        assertBool
          ("digest must be lowercase hex: " <> Text.unpack d)
          (Text.all (`elem` ("0123456789abcdef" :: String)) (Text.drop 7 d)),
      -- The golden values below pin the canonicalisation rule. If one
      -- of these fails and the fixture has not changed, the encoding
      -- changed, and every digest recorded by an earlier build has
      -- become unverifiable. That is a major bump of
      -- evidenceSchemaVersion, not a value to paste over.
      testCase "the request commitment matches the golden value" $ do
        env <- loadFixture
        commitmentDigest env
          @?= "sha256:ee1baf81dad750bb61bbcd6a737b8266c206a4288403510be5e10cace20b5798",
      testCase "the configuration digest matches the golden value" $ do
        env <- loadFixture
        configurationDigest env
          @?= "sha256:858f0d5ec35ba6f8bac39140c6523785abcbf4e8007c770c1ba2e13f0e72d6b5",
      testCase "the configuration digest ignores content, the commitment does not" $ do
        let ask subject =
              object
                [ "model" .= ("m" :: Text.Text),
                  "messages"
                    .= [ object
                           [ "role" .= ("user" :: Text.Text),
                             "content" .= (subject :: Text.Text)
                           ]
                       ]
                ]
            -- Same length on purpose: the projection keeps a character
            -- count, so differing lengths would change the digest for
            -- a reason unrelated to content.
            q1 = ask "hello"
            q2 = ask "world"
        configurationDigest q1 @?= configurationDigest q2
        assertBool
          "the commitment digest must distinguish different content"
          (commitmentDigest q1 /= commitmentDigest q2),
      testCase "the configuration digest still separates different configurations" $ do
        let withModel m = object ["model" .= (m :: Text.Text)]
        assertBool
          "different models must produce different configuration digests"
          (configurationDigest (withModel "a") /= configurationDigest (withModel "b")),
      testCase "a non-object envelope projects to null" $
        configurationProjection (String "not an envelope") @?= Aeson.Null
    ]

-- ============================================================
-- Redaction
-- ============================================================

-- | The four markers below are the API key, the prompt body, the
-- reasoning text, and a tool-call argument payload planted in the
-- fixture. The assertion is on the encoded bytes rather than on the
-- projected structure, because the claim being tested is that none of
-- them survives into the output no matter how it got there.
redactionTests :: TestTree
redactionTests =
  testGroup
    "redaction"
    [ testCase "the configuration projection drops all content" $ do
        env <- loadFixture
        let encoded = BS8.unpack (canonicalEncode (configurationProjection env))
        mapM_
          ( \marker ->
              assertBool
                (marker <> " survived into the configuration projection: " <> encoded)
                (not (marker `isInfix` encoded))
          )
          [ "sk-baikai-fixture-secret-key",
            "PROMPT-BODY-MARKER",
            "SYSTEM-PROMPT-BODY-MARKER",
            "REASONING-TEXT-MARKER",
            "TOOL-PAYLOAD-MARKER",
            "Fetch a quarterly report by identifier."
          ],
      testCase "the projection keeps the configuration it is supposed to" $ do
        env <- loadFixture
        let encoded = BS8.unpack (canonicalEncode (configurationProjection env))
        mapM_
          ( \kept ->
              assertBool
                (kept <> " should have been kept, but was not: " <> encoded)
                (kept `isInfix` encoded)
          )
          [ "claude-opus-4-6",
            "budget_tokens",
            "max_tokens",
            "temperature",
            -- A tool's name is configuration; its description is not.
            "fetch_report"
          ],
      testCase "the commitment digest does see the content" $ do
        env <- loadFixture
        let encoded = BS8.unpack (canonicalEncode env)
        assertBool
          "the commitment input must contain the prompt body"
          ("PROMPT-BODY-MARKER" `isInfix` encoded)
    ]
  where
    isInfix needle haystack =
      Text.isInfixOf (Text.pack needle) (Text.pack haystack)

-- ============================================================
-- Observed
-- ============================================================

observedTests :: TestTree
observedTests =
  testGroup
    "observed"
    [ testCase "encodes Unobserved as the string \"unobserved\"" $
        Aeson.toJSON (Unobserved :: Observed Text.Text) @?= String "unobserved",
      testCase "encodes an observed value under an observed key" $
        Aeson.toJSON (Observed ("claude-opus-4-6" :: Text.Text))
          @?= object ["observed" .= ("claude-opus-4-6" :: Text.Text)],
      testCase "round-trips through JSON in both directions" $ do
        roundTrip (Observed ("m" :: Text.Text))
        roundTrip (Unobserved :: Observed Text.Text),
      testCase "observedValue reports absence rather than defaulting" $ do
        observedValue (Observed ("m" :: Text.Text)) @?= Just "m"
        observedValue (Unobserved :: Observed Text.Text) @?= Nothing,
      -- Strict evidence mode compares a record's strength against the
      -- caller's requirement with (>=), so this ordering is load-bearing
      -- rather than cosmetic.
      testCase "evidence strength ascends in the order strict mode compares" $ do
        let ascending =
              [ EvidenceRequestedOnly,
                EvidenceCorrelated,
                EvidenceModelObserved,
                EvidenceFullyObserved
              ]
        assertBool
          "EvidenceStrength constructors must ascend as declared"
          (and (zipWith (<) ascending (drop 1 ascending))),
      testCase "noThinkingRequested records absence, not an unsupported level" $ do
        requested noThinkingRequested @?= Nothing
        mode noThinkingRequested @?= ThinkingModeAbsent
        adjustments noThinkingRequested @?= [],
      -- Destructured rather than accessed by selector: 'runId',
      -- 'attempt', and 'supersedes' name a field on both
      -- 'EvidenceRequest' and 'ModelCallEvidence', and under
      -- DuplicateRecordFields a bare selector is ambiguous. Library
      -- code reaches these through the generic-lens labels
      -- (@r ^. #runId@) that the rest of this codebase uses.
      testCase "evidenceRequest defaults to best effort, attempt one" $
        case evidenceRequest "run-42" of
          EvidenceRequest
            { runId = rid,
              strictness = strict,
              attempt = att,
              supersedes = prev
            } -> do
              rid @?= "run-42"
              strict @?= EvidenceBestEffort
              att @?= 1
              prev @?= Nothing
    ]
  where
    roundTrip :: Observed Text.Text -> IO ()
    roundTrip v = case Aeson.fromJSON (Aeson.toJSON v) of
      Aeson.Success v' -> v' @?= v
      Aeson.Error e -> assertFailure ("round trip failed: " <> e)

-- ============================================================
-- Fixture loading
-- ============================================================

fixturePath :: FilePath
fixturePath = "test/fixtures/evidence-request.json"

-- | The recorded request envelope both golden tests hash. It carries
-- an API key in a header-shaped field, a prompt body, reasoning text,
-- and a tool-call argument payload, so one fixture serves the digest
-- tests and the redaction tests.
loadFixture :: IO Value
loadFixture = do
  raw <- Aeson.eitherDecodeFileStrict' fixturePath
  case raw of
    Left err -> assertFailure ("could not read " <> fixturePath <> ": " <> err)
    Right v -> pure v
