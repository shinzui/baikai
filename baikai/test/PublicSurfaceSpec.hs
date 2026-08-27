{-# LANGUAGE OverloadedRecordDot #-}

-- | A downstream consumer's view of baikai, compiled.
--
-- This module imports __only__ modules a published consumer can import:
-- no @Baikai.Prelude@, no @Control.Lens@, no generic-lens, no
-- @.Internal@ module. Everything it does, it does with record update,
-- plain selectors and the exported base values.
--
-- Its value is that it compiles. Plan 43 chose compile-time probes over
-- a golden @:browse@ dump, because a dump goes stale silently while a
-- module that sees what a downstream sees fails the build the moment a
-- name a consumer needs stops being exported — or the moment a record
-- can no longer be built without the constructor this release hid.
--
-- It exports one 'TestTree' so the suite runs the few facts that are
-- cheap to assert here; the compilation is the real test.
module PublicSurfaceSpec (tests) where

import Baikai
import Baikai.Cost.Log (CallLogConfig (enabled, path), callLogConfig)
import Baikai.Embedding qualified as Embedding
import Data.Aeson (Value (Null))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "public surface"
    [ testCase "every hidden record is buildable with record update alone" $ do
        probeTool.name @?= "probe"
        probeLog.path @?= "/dev/null"
        probeLog.enabled @?= True
        Embedding.modelId probeEmbedding @?= "text-embedding-probe"
        headerCount @?= 1,
      testCase "a provider registered from apiProvider dispatches" $ do
        reg <- newProviderRegistryFrom [probeProvider]
        resp <- completeRequestWith reg probeModel probeContext probeOptions
        -- The stream is empty, so reassembly produces a response with no
        -- content and no error. What matters is that dispatch found the
        -- handler and that a consumer could build it.
        assertBool "the call produced no error" (responseError resp == Nothing)
    ]

-- | Built from 'apiProvider' — re-exported by the umbrella — not from a
-- constructor.
probeProvider :: ApiProvider
probeProvider = apiProvider (Custom "public-surface-probe") (\_ _ _ -> Stream.fromList [])

probeModel :: Model
probeModel =
  emptyModel
    { modelId = "probe-model",
      api = Custom "public-surface-probe",
      provider = "probe"
    }

probeContext :: Context
probeContext = emptyContext {messages = V.singleton (user "hello")}

probeOptions :: Options
probeOptions = emptyOptions {maxTokens = Just 16}

probeTool :: Tool
probeTool = mkTool "probe" "a probe" Null

probeLog :: CallLogConfig
probeLog = callLogConfig "/dev/null"

-- Qualified because @modelId@ alone does not name a type: 'Model',
-- 'EmbeddingModel' and 'InteractiveLaunchRequest' all have it, and under
-- @DuplicateRecordFields@ a record update whose fields do not determine
-- the datatype is ambiguous. Hiding constructors did not cause that and
-- does not change it; a consumer either qualifies, as here, or reaches
-- for generic-lens.
probeEmbedding :: Embedding.EmbeddingModel
probeEmbedding =
  Embedding.emptyEmbeddingModel {Embedding.modelId = "text-embedding-probe"}

-- | Two spellings of one header name, through the public 'HeaderName'.
headerCount :: Int
headerCount =
  Map.size (Map.fromList [("X-Probe", "a"), ("x-probe", "b")] :: Map.Map HeaderName Text)
