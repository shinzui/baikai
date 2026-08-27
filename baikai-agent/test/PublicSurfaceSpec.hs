{-# LANGUAGE OverloadedRecordDot #-}

-- | A downstream consumer's view of @baikai-agent@'s library, compiled.
--
-- Imports only the two public modules and builds each record the way a
-- consumer now must: from its exported base value by record update,
-- since none of the four constructors is exported any more. The
-- compilation is the test.
module PublicSurfaceSpec (tests) where

import Baikai.Agent
  ( AgentCapability (AgentReadOnly),
    AgentOutputFormat (JsonFormat),
    AgentOutputMode (CaptureOutput),
    AgentProvider (AgentClaude),
  )
import Baikai.Agent.Cli
  ( AgentCliCommand (AgentList),
    AgentCliOptions (jsonOutput, runId),
    AgentCliRun (exitCode, standardOutput),
    agentCliOptions,
    agentCliRun,
  )
import Baikai.Agent.Config
  ( AgentConfigPaths (repoConfig, repositoryRoot, userConfig),
    AgentJob (capability, modelId, output, outputFormat, provider, workingDir),
    agentJob,
    emptyAgentConfigPaths,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "public surface (baikai-agent)"
    [ testCase "agentJob supplies the three required fields and sane defaults" $ do
        let job = (agentJob AgentClaude "." AgentReadOnly) {modelId = Just "probe-model"}
        job.provider @?= AgentClaude
        job.workingDir @?= "."
        job.capability @?= AgentReadOnly
        job.modelId @?= Just "probe-model"
        job.output @?= (agentJob AgentClaude "." AgentReadOnly).output
        (job {outputFormat = JsonFormat}).outputFormat @?= JsonFormat
        (job {output = CaptureOutput}).output @?= CaptureOutput,
      testCase "the CLI records are built from their bases" $ do
        let opts = (agentCliOptions AgentList) {jsonOutput = True, runId = Just "run-1"}
        opts.jsonOutput @?= True
        opts.runId @?= Just "run-1"
        let run = (agentCliRun 0) {standardOutput = "ok"}
        run.exitCode @?= 0
        run.standardOutput @?= "ok",
      testCase "emptyAgentConfigPaths names no file and roots at the current directory" $ do
        emptyAgentConfigPaths.userConfig @?= Nothing
        emptyAgentConfigPaths.repoConfig @?= Nothing
        emptyAgentConfigPaths.repositoryRoot @?= "."
    ]
