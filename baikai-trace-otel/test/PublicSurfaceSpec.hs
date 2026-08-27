{-# LANGUAGE OverloadedRecordDot #-}

-- | A downstream consumer's view of @baikai-trace-otel@, compiled.
--
-- Imports only the public module and builds 'OtelSinkOptions' the way a
-- consumer now must: from 'defaultOtelSinkOptions' by record update,
-- since the constructor is no longer exported. The compilation is the
-- test.
module PublicSurfaceSpec (tests) where

import Baikai.Trace.Sink.OpenTelemetry
  ( OtelSinkOptions (includePromptSummary, parentContext, spanName),
    defaultOtelSinkOptions,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "public surface (baikai-trace-otel)"
    [ testCase "OtelSinkOptions is built from its base by record update" $ do
        let opts = defaultOtelSinkOptions {spanName = "probe", includePromptSummary = True}
        opts.spanName @?= "probe"
        opts.includePromptSummary @?= True
        -- 'Context' has no Eq, so the field is checked for absence
        -- rather than compared.
        assertBool "the default parent context is absent" (isNothingContext opts)
    ]
  where
    isNothingContext opts = case opts.parentContext of
      Nothing -> True
      Just _ -> False
