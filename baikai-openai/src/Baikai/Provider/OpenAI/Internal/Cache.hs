{-# LANGUAGE OverloadedRecordDot #-}

-- | Internal native cache planning and terminal pricing. One prepared policy
-- supplies the wire controls, prefix placement and effective billing duration.
module Baikai.Provider.OpenAI.Internal.Cache
  ( CachePlan (..),
    responsesCachePlan,
    chatCachePlan,
    cacheCost,
  )
where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Compat
import Baikai.Cost qualified as C
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Model qualified as M
import Baikai.Options (Options (..))
import Baikai.Usage qualified as U
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import Data.Text (Text)

data CachePlan = CachePlan
  { cacheFields :: ![(Key, Value)],
    markPrefix :: !Bool,
    effectiveRetention :: !(Maybe CacheRetention)
  }
  deriving stock (Eq, Show)

responsesCachePlan :: M.Model -> Options -> Either Text CachePlan
responsesCachePlan m opts = do
  let c = M.openaiResponsesCompatFor m
      -- Absent metadata preserves the prior Responses mappings, but never
      -- invents explicit breakpoint support.
      policy = case c.nativeCachePolicy of
        Just p -> p
        Nothing
          | c.supportsPromptCacheOptions -> NativeCacheModern False False
          | otherwise -> NativeCacheLegacy True c.supportsLongCacheRetention
  plan m Nothing (Just policy) opts

chatCachePlan :: M.Model -> Options -> Either Text CachePlan
chatCachePlan m opts =
  let c = M.openaiCompletionsCompatFor m
   in do
        native <- plan m c.cacheControlFormat c.nativeCachePolicy opts
        -- The existing compatible-host downgrade is an independent wire contract.
        pure $ case (c.cacheControlFormat, opts.cacheRetention) of
          (Just CacheControlFormatAnthropic, Just CacheRetentionShort) -> native {effectiveRetention = Just CacheRetentionShort}
          (Just CacheControlFormatAnthropic, Just CacheRetentionLong) -> native {effectiveRetention = Just (if c.supportsLongCacheRetention then CacheRetentionLong else CacheRetentionShort)}
          _ -> native

plan :: M.Model -> Maybe CacheControlFormat -> Maybe NativeCachePolicy -> Options -> Either Text CachePlan
plan m format policy opts = named $ do
  validateNativeCachePolicy format policy
  case M.pricingPolicy m of
    Just p -> M.validatePricingPolicy p
    Nothing -> Right ()
  case policy of
    Just (NativeCacheModern True _) -> requireLongRates
    _ -> Right ()
  case opts.cacheRetention of
    Nothing -> pure absent
    Just CacheRetentionNone -> pure absent
    Just requested -> case policy of
      Nothing -> pure absent -- native Chat is opt-in through endpoint facts
      Just NativeCacheUnsupported -> refuse
      Just (NativeCacheLegacy short long) -> case requested of
        CacheRetentionShort | short -> legacy "in_memory"
        CacheRetentionLong | long -> legacy "24h"
        _ -> refuse
      Just (NativeCacheModern long prefix) -> case requested of
        CacheRetentionShort -> modern "30m" prefix CacheRetentionShort
        CacheRetentionLong | long -> modern "12h" prefix CacheRetentionLong
        _ -> refuse
  where
    named = either (Left . ((M.modelId m <> ": ") <>)) Right
    absent = CachePlan [] False $ case policy of
      Just (NativeCacheModern _ _) -> Just CacheRetentionShort
      _ -> Nothing
    refuse = Left "native cache policy cannot honor requested retention"
    -- Legacy 24h has no duration premium. Always resolve base write prices.
    legacy ttl = pure (CachePlan [("prompt_cache_retention", String ttl)] False (Just CacheRetentionShort))
    modern ttl prefix duration = pure (CachePlan [("prompt_cache_options", object ["ttl" .= (ttl :: Text)])] prefix (Just duration))
    requireLongRates = case M.pricingPolicy m of
      Just p
        | Just _ <- p.longCacheWriteCost,
          all (\t -> t.longCacheWriteCost /= Nothing) p.inputTiers ->
            Right ()
      _ -> Left "modern Long requires base and every tier long cache-write rates"

-- | Unknown duration remains an explicit estimate only when it matters to
-- reported writes. Do not infer duration from a read counter.
cacheCost :: Maybe CacheRetention -> M.Model -> U.Usage -> C.Cost
cacheCost duration m usage = C.estimateCost reasons (Pricing.computeCostForService duration Nothing m usage)
  where
    reasons = [C.CacheDurationNotReported | duration == Nothing, usage.cacheWriteTokens > 0, durationSensitive]
    durationSensitive = case m.pricingPolicy of
      Nothing -> False
      Just p -> p.longCacheWriteCost /= Nothing || any (\t -> t.longCacheWriteCost /= Nothing) p.inputTiers
