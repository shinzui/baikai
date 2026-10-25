{-# LANGUAGE OverloadedRecordDot #-}

module NativeCacheSpec (tests) where

import Baikai hiding (model)
import Baikai.Compat (NativeCachePolicy (..), nativeCachePolicy)
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Internal.Cache qualified as Cache
import Baikai.Provider.OpenAI.Internal.Stream qualified as Chat
import Baikai.Provider.OpenAI.Internal.Usage qualified as Billing
import Baikai.Provider.OpenAI.Responses.Request qualified as Responses
import Baikai.Provider.OpenAI.Responses.Stream qualified as Responses
import Baikai.Provider.OpenAI.Shape qualified as Shape
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Streamly.Data.Stream qualified as Stream
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "native cache contract"
    [ testCase "Responses preserves exactly one identical prefix across fresh questions" $ do
        a <- mapped (systemUser "private prefix" "first") short
        b <- mapped (systemUser "private prefix" "second") short
        field "instructions" a.requestBody @?= Nothing
        field "store" a.requestBody @?= Just (Bool False)
        take 1 (items a.requestBody) @?= take 1 (items b.requestBody)
        assertBool "questions differ" (drop 1 (items a.requestBody) /= drop 1 (items b.requestBody))
        head (items a.requestBody) @?= developer "private prefix"
        a.effectiveRetention @?= Just CacheRetentionShort,
      testCase "absent/None controls preserve wire; default duration is known only for modern policy" $ do
        forM_ [Nothing, Just CacheRetentionNone] $ \preference -> do
          r <- mapped (systemUser "prefix" "question") (emptyOptions & #cacheRetention .~ preference)
          field "instructions" r.requestBody @?= Just (String "prefix")
          field "prompt_cache_options" r.requestBody @?= Nothing
          length (items r.requestBody) @?= 1
          r.effectiveRetention @?= Just CacheRetentionShort,
      testCase "missing/empty system never becomes an empty cacheable block" $
        forM_ [Nothing, Just ""] $ \prompt -> do
          r <- mapped (contextOf [user "question"] & #systemPrompt .~ prompt) short
          length (items r.requestBody) @?= 1,
      testCase "marker survives tool continuation with opaque reasoning unchanged" $ do
        let opaque = object ["type" .= ("reasoning" :: Text), "id" .= ("rs" :: Text), "summary" .= ([] :: [Value]), "encrypted_content" .= ("SECRET_REPLAY" :: Text)]
            thought = emptyThinkingContent & #replayState .~ Just (ThinkingReplay OpenAIResponses model.modelId (V.singleton opaque))
            response = emptyResponse & #message . #content .~ V.fromList [AssistantThinking thought, AssistantToolCall (ToolCall "call" "lookup" (object []))] & #message . #stopReason .~ ToolUse
        next <- appendToolResult (systemUser "prefix" "question") response (\_ -> pure (toolResultText "result"))
        req <- mapped next short
        take 1 (items req.requestBody) @?= [developer "prefix"]
        items req.requestBody !! 2 @?= opaque
        field "call_id" (items req.requestBody !! 4) @?= Just (String "call"),
      testCase "native Chat marks only initial instructions and retains their role" $ do
        plan <- right (Cache.chatCachePlan chatModel short)
        forM_ ["system", "developer"] $ \role -> do
          let first = object ["role" .= (role :: Text), "content" .= ("prefix" :: Text)]
              rest = [object ["role" .= ("user" :: Text), "content" .= ("question" :: Text)], first]
              body = Shape.applyNativeCache plan (object ["messages" .= (first : rest), "tools" .= ([] :: [Value])])
          field "messages" body @?= Just (A.toJSON (object ["role" .= role, "content" .= [object ["type" .= ("text" :: Text), "text" .= ("prefix" :: Text), "prompt_cache_breakpoint" .= marker]]] : rest))
          field "prompt_cache_options" body @?= Just (object ["ttl" .= ("30m" :: Text)]),
      testCase "legacy native controls accept exactly the declared values and have no premium" $ do
        let legacy policy = chatModel & #compat .~ CompatOpenAICompletions (defaultOpenAICompletionsCompat & #nativeCachePolicy .~ Just policy)
        forM_ [(NativeCacheLegacy True True, CacheRetentionShort, "in_memory"), (NativeCacheLegacy True True, CacheRetentionLong, "24h"), (NativeCacheLegacy False True, CacheRetentionLong, "24h")] $ \(policy, pref, ttl) -> do
          plan <- right (Cache.chatCachePlan (legacy policy) (emptyOptions & #cacheRetention .~ Just pref))
          Cache.cacheFields plan @?= [("prompt_cache_retention", String ttl)]
          Cache.markPrefix plan @?= False
          Cache.effectiveRetention plan @?= Just CacheRetentionShort
        assertLeft (Cache.chatCachePlan (legacy (NativeCacheLegacy False True)) short),
      testCase "absent Responses policy preserves legacy mappings; explicit unsupported wins" $ do
        let base = model & #compat .~ CompatOpenAIResponses defaultOpenAIResponsesCompat
            unsupported = model & #compat .~ CompatOpenAIResponses (defaultOpenAIResponsesCompat & #supportsPromptCacheOptions .~ True & #nativeCachePolicy .~ Just NativeCacheUnsupported)
        p <- right (Cache.responsesCachePlan base short)
        Cache.cacheFields p @?= [("prompt_cache_retention", String "in_memory")]
        Cache.markPrefix p @?= False
        assertLeft (Cache.responsesCachePlan unsupported short),
      testCase "public complete/stream dispatch both endpoints through the same prepared prefix" $
        forM_ [model, chatModel] $ \m -> do
          sent <- newIORef []
          let driver _ _ body _ emit = do
                modifyIORef' sent (<> [body])
                emit (Right (terminal m))
              handler = if m.api == OpenAIResponses then Responses.openaiResponsesStreamWith driver else Chat.openaiChatStreamWith driver
          reg <- newProviderRegistryFrom [apiProvider m.api handler]
          let opts = short & #apiKey .~ Just (ApiKeyLiteral "offline")
          a <- completeRequestWith reg m (systemUser "prefix" "first") opts
          responseError a @?= Nothing
          es <- Stream.toList (streamRequestWith reg m (systemUser "prefix" "second") opts)
          assertBool "stream completes" (case last es of EventDone _ -> True; _ -> False)
          bodies <- readIORef sent
          length bodies @?= 2
          let key = if m.api == OpenAIResponses then "input" else "messages"
              initial body = case field key body of Just (Array xs) -> V.head xs; _ -> Null
          map initial bodies @?= replicate 2 (initial (head bodies))
          assertBool "wire contains explicit marker" ("prompt_cache_breakpoint" `T.isInfixOf` T.pack (show (initial (head bodies)))),
      testCase "public refusals precede invalid credentials and driver for both endpoints" $
        forM_ [model, chatModel] $ \m -> do
          let driver _ _ _ _ _ = assertFailure "driver must not run"
              handler = if m.api == OpenAIResponses then Responses.openaiResponsesStreamWith driver else Chat.openaiChatStreamWith driver
              opts = short & #cacheRetention .~ Just CacheRetentionLong & #apiKey .~ Just (ApiKeyEnv "BAIKAI_CACHE_TEST_MISSING_KEY")
          reg <- newProviderRegistryFrom [apiProvider m.api handler]
          r <- completeRequestWith reg m emptyContext opts
          assertBool "model-named local refusal" (maybe False (\e -> T.isInfixOf m.modelId e.message) (responseError r))
          events <- Stream.toList (streamRequestWith reg m emptyContext opts)
          assertBool "stream refuses" (case last events of EventError _ -> True; _ -> False),
      testCase "contradictory controls and missing long prices fail locally" $ do
        let bad = chatModel & #compat .~ CompatOpenAICompletions (defaultOpenAICompletionsCompat & #cacheControlFormat .~ Just CacheControlFormatAnthropic & #nativeCachePolicy .~ Just (NativeCacheModern False True))
            longModel = model & #compat .~ CompatOpenAIResponses (defaultOpenAIResponsesCompat & #nativeCachePolicy .~ Just (NativeCacheModern True True))
        assertLeft (Cache.chatCachePlan bad short)
        forM_ [Nothing, Just (PricingPolicy [] Nothing), Just (PricingPolicy [InputPriceTier 100 (ModelCost 2 3 1 2) Nothing] (Just 4))] $ \policy ->
          assertLeft (Cache.responsesCachePlan (longModel & #pricingPolicy .~ policy) (short & #cacheRetention .~ Just CacheRetentionLong)),
      testCase "synthetic long/short pricing reaches both successful and partial-error terminals" $
        forM_ [model, chatModel] $ \base -> forM_ [CacheRetentionShort, CacheRetentionLong] $ \duration -> forM_ [False, True] $ \failed -> do
          let m =
                base
                  & #cost .~ ModelCost 1 2 (1 / 10) (5 / 4)
                  & #pricingPolicy .~ Just (PricingPolicy [InputPriceTier 100 (ModelCost 2 4 (1 / 5) (5 / 2)) (Just 5)] (Just (5 / 2)))
                  & #compat
                    .~ ( if base.api == OpenAIResponses
                           then CompatOpenAIResponses (defaultOpenAIResponsesCompat & #nativeCachePolicy .~ Just (NativeCacheModern True True))
                           else CompatOpenAICompletions (defaultOpenAICompletionsCompat & #nativeCachePolicy .~ Just (NativeCacheModern True True))
                       )
              isResponses = m.api == OpenAIResponses
              (ik, ok, dk) = if isResponses then ("input_tokens", "output_tokens", "input_tokens_details") else ("prompt_tokens", "completion_tokens", "prompt_tokens_details")
              input = object [ik .= (1000 :: Int), dk .= object ["cached_tokens" .= (100 :: Int), "cache_write_tokens" .= (200 :: Int)]]
              output = object [ok .= (10 :: Int)]
              frame usage = if isResponses then object ["type" .= ("response.in_progress" :: Text), "response" .= object ["service_tier" .= ("default" :: Text), "usage" .= usage]] else object ["service_tier" .= ("default" :: Text), "usage" .= usage, "choices" .= ([] :: [Value])]
              driver _ _ _ _ emit = do
                mapM_ (emit . Right . frame) [input, output, output]
                if failed then emit (Left (providerError "synthetic interruption")) else emit (Right (terminal m))
              handler = if isResponses then Responses.openaiResponsesStreamWith driver else Chat.openaiChatStreamWith driver
              opts = short & #cacheRetention .~ Just duration & #apiKey .~ Just (ApiKeyLiteral "offline") & #evidence .~ Just (evidenceRequest "synthetic-cache-billing")
          r <- streamingComplete handler m emptyContext opts
          let u = r.message.usage
          (u.inputTokens, u.cacheReadTokens, u.cacheWriteTokens, u.outputTokens, u.totalTokens) @?= (700, 100, 200, 10, 1010)
          u.cost.usd @?= if duration == CacheRetentionShort then 49 / 25000 else 123 / 50000
          u.cost.basis.estimateReasons @?= Set.empty
          case r.evidence of Just e -> e.usage @?= Observed u; Nothing -> assertFailure "missing terminal evidence",
      testCase "synthetic duration prices cross input tiers and unknown duration stays estimated" $ do
        let m = model & #cost .~ ModelCost 1 2 (1 / 10) (5 / 4) & #pricingPolicy .~ Just (PricingPolicy [InputPriceTier 100 (ModelCost 2 4 (1 / 5) (5 / 2)) (Just 5)] (Just (5 / 2)))
            u = observeBilling [BillingServiceTier "default"] (zeroUsage & #cacheWriteTokens .~ 200 & #totalTokens .~ 200)
        (Cache.cacheCost (Just CacheRetentionShort) m u).usd @?= 1 / 2000
        (Cache.cacheCost (Just CacheRetentionLong) m u).usd @?= 1 / 1000
        assertBool "duration estimate" (CacheDurationNotReported `Set.member` (Cache.cacheCost Nothing m u).basis.estimateReasons),
      testCase "duration details check totals and selected TTL without adding writes" $ do
        let usage = object ["input_tokens" .= (100 :: Int), "output_tokens" .= (1 :: Int), "input_tokens_details" .= object ["cached_tokens" .= (0 :: Int), "cache_write_tokens" .= (100 :: Int), "cache_write_tokens_details" .= object ["ttl_30m_tokens" .= (40 :: Int), "ttl_12h_tokens" .= (60 :: Int)]]]
        u <- maybe (assertFailure "usage absent") pure (Billing.readUsage Billing.ResponsesUsage usage)
        let checked = Billing.checkCacheDuration Billing.ResponsesUsage (Just CacheRetentionShort) (Just usage) u
        checked.cacheWriteTokens @?= 100
        inconsistent <$> checked.availability @?= Just True,
      testCase "configuration evidence keeps TTL and placement but excludes private payloads" $ do
        a <- mapped (systemUser "PRIVATE_PROMPT" "SECRET_QUERY") short
        let body = a.requestBody
            changed = case body of Object o -> Object (KM.insert "prompt_cache_options" (object ["ttl" .= ("12h" :: Text), "private" .= ("PRIVATE_NESTED" :: Text)]) o); _ -> body
            projected = T.pack (show (configurationProjection changed))
        forM_ ["PRIVATE_PROMPT", "SECRET_QUERY", "PRIVATE_NESTED"] $ \secret -> assertBool "no content leaked" (not (secret `T.isInfixOf` projected))
        assertBool "ttl changes configuration" (configurationDigest body /= configurationDigest changed)
        sameLength <- mapped (systemUser "REDACTED_VALUE" "HIDDEN_QUERY") short
        configurationDigest body @?= configurationDigest sameLength.requestBody
    ]

model :: Model
model = Models.openai_gpt_6_luna & #modelId .~ "renamed-responses"

chatModel :: Model
chatModel = Models.openai_gpt_5_6 & #modelId .~ "renamed-chat"

short :: Options
short = emptyOptions & #cacheRetention .~ Just CacheRetentionShort

marker :: Value
marker = object ["mode" .= ("explicit" :: Text)]

developer :: Text -> Value
developer text = object ["role" .= ("developer" :: Text), "content" .= [object ["type" .= ("input_text" :: Text), "text" .= text, "prompt_cache_breakpoint" .= marker]]]

field :: A.Key -> Value -> Maybe Value
field k (Object o) = KM.lookup k o
field _ _ = Nothing

items :: Value -> [Value]
items body = case field "input" body of Just (Array xs) -> V.toList xs; _ -> []

mapped :: Context -> Options -> IO Responses.PreparedRequest
mapped ctx opts = right (Responses.mapRequest model ctx opts)

right :: Either Text a -> IO a
right = either (assertFailure . T.unpack) pure

assertLeft :: Either Text a -> IO ()
assertLeft (Left err) = assertBool "model named" ("renamed" `T.isInfixOf` err)
assertLeft (Right _) = assertFailure "expected refusal"

terminal :: Model -> Value
terminal m
  | m.api == OpenAIResponses = object ["type" .= ("response.completed" :: Text), "response" .= object ["id" .= ("resp" :: Text), "output" .= ([] :: [Value])]]
  | otherwise = object ["choices" .= [object ["delta" .= object [], "finish_reason" .= ("stop" :: Text)]]]
