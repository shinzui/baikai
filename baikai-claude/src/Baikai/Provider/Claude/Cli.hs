-- | Provider that drives the @claude -p@ non-interactive CLI as a
-- subprocess.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.AnthropicMessagesCli' handler with default config.
-- For non-default executable paths or extra args, use 'registerWith'
-- and supply a custom 'ClaudeCliConfig'.
--
-- The 'Response' this provider returns carries whatever the tool
-- reported about its own run: the token counts and total cost from the
-- result event's @usage@ block, and the tool's @session_id@ as the
-- response identifier. A tool that reports none of that yields zeroes
-- and 'Nothing', which is an accurate record of its silence rather
-- than a claim that the call was free. CLI providers do not
-- participate in tool calling. Provider failures are returned in-band
-- as error-shaped responses; the masterplan's Decision Log records the
-- reasoning.
--
-- Evidence from this transport is deliberately weaker than from the
-- Messages API. A tool that exits zero has demonstrated that it ran,
-- not which model served the request, so a successful exit never
-- raises the recorded 'Baikai.Evidence.EvidenceStrength' — see
-- 'Baikai.Provider.Cli.Internal.subprocessStrength'.
module Baikai.Provider.Claude.Cli
  ( ClaudeCliConfig,
    executable,
    extraArgs,
    workingDir,
    claudeCliCommand,
    claudeCliThinking,
    defaultClaudeCliConfig,
    claudeCliProvider,
    register,
    registerWith,
    registerWithRegistry,
    registerWithRegistryAndConfig,
  )
where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context)
import Baikai.Error (BaikaiError, processError, providerError)
import Baikai.Evidence qualified as Ev
import Baikai.Evidence.Build qualified as Build
import Baikai.Message (AssistantPayload (..))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Cli.Internal qualified as Internal
import Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    registerApiProvider,
    registerApiProviderWith,
  )
import Baikai.Response qualified as Resp
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
import Baikai.ThinkingLevel (ThinkingLevel (ThinkingMinimal), renderThinkingLevel)
import Baikai.Usage (Usage, zeroUsage)
import Control.Exception (SomeException, displayException, fromException)
import Control.Lens ((&), (.~), (^.))
import Cradle
  ( ExitCode (..),
    StderrRaw (..),
    StdoutRaw (..),
    addArgs,
    cmd,
    run,
    setNoStdin,
    setWorkingDir,
  )
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)

-- | Configuration for the @claude -p@ subprocess.
data ClaudeCliConfig = ClaudeCliConfig
  { executable :: !FilePath,
    extraArgs :: ![Text],
    workingDir :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

defaultClaudeCliConfig :: ClaudeCliConfig
defaultClaudeCliConfig =
  ClaudeCliConfig
    { executable = "claude",
      extraArgs = mempty,
      workingDir = Nothing
    }

-- | Install the CLI handler with 'defaultClaudeCliConfig'.
register :: IO ()
register = registerApiProvider (claudeCliProvider defaultClaudeCliConfig)

-- | First-class Claude CLI provider value for a caller-supplied config.
claudeCliProvider :: ClaudeCliConfig -> ApiProvider
claudeCliProvider cfg =
  ApiProvider
    { apiTag = AnthropicMessagesCli,
      stream = liftCompleteToStream (runClaudeCli cfg),
      complete = runClaudeCli cfg,
      -- The model plays no part: this transport's only reasoning
      -- control is a command-line flag derived from Options alone.
      describeThinking = \_ opts -> claudeCliThinking opts
    }

-- | Install the CLI handler with a caller-supplied config.
--
-- The CLI binary runs in batch mode; there is no intra-response
-- streaming on the wire. The 'stream' field therefore wraps the
-- batch 'runClaudeCli' through 'liftCompleteToStream', producing a
-- synthetic one-shot event stream
-- (@EventStart, TextStart 0, TextDelta 0 body, TextEnd 0, EventDone@)
-- the moment the subprocess returns. 'complete' is left as the
-- direct batch path so it preserves 'Response.responseId' and the
-- measured 'Response.latencyMs' (going through a
-- 'streamingComplete' round trip would lose the former and recompute
-- the latter from synthetic events). EP-3's Decision Log explains
-- the deviation from the plan's "complete = streamingComplete .
-- stream" default.
registerWith :: ClaudeCliConfig -> IO ()
registerWith cfg = registerApiProvider (claudeCliProvider cfg)
{-# DEPRECATED registerWith "use registerApiProvider (claudeCliProvider cfg)" #-}

-- | Install the CLI handler with 'defaultClaudeCliConfig' into an explicit
-- registry.
registerWithRegistry :: ProviderRegistry -> IO ()
registerWithRegistry reg = registerWithRegistryAndConfig reg defaultClaudeCliConfig
{-# DEPRECATED registerWithRegistry "use registerApiProviderWith reg (claudeCliProvider defaultClaudeCliConfig)" #-}

-- | Install the CLI handler with a caller-supplied config into an explicit
-- registry.
registerWithRegistryAndConfig :: ProviderRegistry -> ClaudeCliConfig -> IO ()
registerWithRegistryAndConfig reg cfg =
  registerApiProviderWith
    reg
    (claudeCliProvider cfg)
{-# DEPRECATED registerWithRegistryAndConfig "use registerApiProviderWith reg (claudeCliProvider cfg)" #-}

-- | Render the executable and arguments for a @claude -p@ batch call.
-- The prompt is preceded by @--@ so dash-leading prompts and variadic
-- flags in 'extraArgs' cannot be parsed as options.
claudeCliCommand :: ClaudeCliConfig -> Model -> Context -> Options -> (FilePath, [String])
claudeCliCommand cfg m ctx opts =
  ( cfg ^. #executable,
    ["-p"]
      <> modelArgs m
      <> ["--output-format", "json", "--no-session-persistence"]
      <> systemPromptArgs ctx
      <> effortArgs opts
      <> fmap Text.unpack (cfg ^. #extraArgs)
      <> ["--", Text.unpack (Internal.renderPrompt ctx)]
  )

-- | Render @--effort@ from 'Options.thinking'. Claude's @--effort@ has
-- no @minimal@, so the lowest Baikai level collapses to @low@; when
-- 'thinking' is unset, no effort flag is emitted.
effortArgs :: Options -> [String]
effortArgs opts = case opts ^. #thinking of
  Nothing -> []
  Just lvl -> ["--effort", Text.unpack (claudeEffortValue lvl)]

claudeEffortValue :: ThinkingLevel -> Text
claudeEffortValue ThinkingMinimal = "low"
claudeEffortValue lvl = renderThinkingLevel lvl

-- | What the caller's reasoning-effort preference became on this
-- transport's command line.
--
-- Derived from 'claudeEffortValue' itself rather than from a table
-- written beside it: the adjustment is recorded exactly when the word
-- that reaches @--effort@ differs from the canonical level name, so the
-- description cannot drift away from what the argument vector actually
-- carries. At present that is the single @minimal -> low@ collapse, and
-- a caller asking for @minimal@ and a caller asking for @low@ produce
-- byte-identical command lines — which is precisely why the collapse
-- has to be written down somewhere.
claudeCliThinking :: Options -> Ev.ThinkingTranslation
claudeCliThinking opts = case opts ^. #thinking of
  Nothing -> Ev.noThinkingRequested
  Just lvl ->
    let wire = claudeEffortValue lvl
     in Ev.ThinkingTranslation
          { requested = Just lvl,
            mode = Ev.ThinkingModeFlag,
            effortText = Just wire,
            budgetTokens = Nothing,
            wireField = Just "--effort",
            adjustments = [Ev.EffortClamped lvl wire | wire /= renderThinkingLevel lvl]
          }

systemPromptArgs :: Context -> [String]
systemPromptArgs ctx = case ctx ^. #systemPrompt of
  Nothing -> []
  Just sp -> ["--system-prompt", Text.unpack sp]

modelArgs :: Model -> [String]
modelArgs m = case Text.strip (m ^. #modelId) of
  "" -> []
  mid -> ["--model", Text.unpack mid]

runClaudeCli :: ClaudeCliConfig -> Model -> Context -> Options -> IO Resp.Response
runClaudeCli cfg m ctx opts = do
  let (exe, args) = claudeCliCommand cfg m ctx opts
  start <- getCurrentTime
  executed <-
    Internal.trySync $
      run $
        cmd exe
          & addArgs args
          & setNoStdin
          & Internal.maybeApply (cfg ^. #workingDir) setWorkingDir
  end <- getCurrentTime
  -- The argument vector is the envelope: for a subprocess it is what
  -- crossed the boundary, and there is nothing else to describe the
  -- launch with. Built lazily and dropped unforced when the caller
  -- asked for no evidence.
  let evidenceFor mReport st mErr = do
        prepared <-
          Build.minimalEvidence
            m
            opts
            Ev.TransportSubprocess
            (claudeCliThinking opts)
            (Internal.argvEnvelope exe args)
            start
            end
            st
            mErr
        traverse (observeClaudeCli exe mReport st) prepared
      failedWith mReport err = do
        ev <- evidenceFor mReport Ev.CallFailed (Just err)
        let resp = Resp.errorResponse m end (millisBetween start end) err
        pure resp {Resp.evidence = ev, Resp.responseId = mReport >>= (^. #sessionId)}
  case executed of
    Left ex -> failedWith Nothing (exceptionToError ex)
    Right (exitCode, StdoutRaw out, StderrRaw err) -> case exitCode of
      ExitFailure n -> failedWith Nothing (processError n (Internal.decodeUtf8Lenient err))
      ExitSuccess -> case Internal.decodeClaudeCliResult out of
        Left e -> failedWith Nothing e
        Right r ->
          if r ^. #isError
            then failedWith (Just r) (providerError (r ^. #result))
            else do
              ev <- evidenceFor (Just r) Ev.CallSucceeded Nothing
              let resp = mkResponse m start end r
              pure resp {Resp.evidence = ev}

-- | Fill in what the tool reported and what baikai knows about the
-- process it launched.
--
-- Only ever reached on a call whose caller asked for evidence, which is
-- what makes the version probe affordable here: it spawns a whole extra
-- subprocess, and charging that to a caller who only wanted an answer
-- from a tool they were about to run anyway would be a visible cost on
-- the cheapest possible call. The parsing it reads is the opposite case
-- and happens unconditionally, because the provider had already decoded
-- the tool's output to find the assistant text.
--
-- Nothing here consults the request. A field the tool did not report
-- stays 'Ev.Unobserved'.
observeClaudeCli ::
  FilePath ->
  Maybe Internal.ClaudeCliReport ->
  Ev.CallStatus ->
  Ev.ModelCallEvidence ->
  IO Ev.ModelCallEvidence
observeClaudeCli exe mReport st ev = do
  identity <- Internal.executableIdentity exe
  let session = observedOf (mReport >>= (^. #sessionId))
      reported = observedOf (mReport >>= (^. #reportedModel))
      used = mReport >>= (^. #usage)
  pure $
    ev
      -- A subprocess has no endpoint URL. Recording the model's base
      -- URL here would suggest an HTTP request that was never made, so
      -- the resolved executable path takes its place.
      & #endpoint . #endpoint .~ Just (fromMaybe (Text.pack exe) (identity ^. #resolvedPath))
      -- For this transport the tool is the implementation, so its own
      -- version is what determines behaviour — not this package's.
      & #endpoint . #implementationVersion .~ (identity ^. #version)
      & #responseId .~ session
      & #observedModel .~ reported
      & #usage .~ observedOf used
      & #responseCommitment .~ commitment used
      & #strength .~ Internal.subprocessStrength session reported
  where
    commitment used = case (st, mReport) of
      (Ev.CallSucceeded, Just r) ->
        Ev.Observed
          ( Ev.commitmentDigest
              (Internal.cliResponseEnvelope (r ^. #result) (fromMaybe zeroUsage used))
          )
      _ -> Ev.Unobserved

observedOf :: Maybe a -> Ev.Observed a
observedOf = maybe Ev.Unobserved Ev.Observed

mkResponse :: Model -> UTCTime -> UTCTime -> Internal.ClaudeCliReport -> Resp.Response
mkResponse m start end r =
  Resp.Response
    { Resp.message =
        AssistantPayload
          { content = Vector.singleton (AssistantText (TextContent (r ^. #result))),
            usage = reportedUsage r,
            stopReason = Stop,
            errorMessage = Nothing,
            timestamp = Just end
          },
      Resp.model = m,
      Resp.api = AnthropicMessagesCli,
      Resp.provider = m ^. #provider,
      Resp.responseId = r ^. #sessionId,
      Resp.latencyMs = millisBetween start end,
      Resp.errorInfo = Nothing,
      Resp.evidence = Nothing
    }

-- | The tool's own token counts, or zeroes when it reported none.
--
-- 'Resp.Response' has nowhere to say "the tool stayed silent", so a
-- silent tool still yields 'zeroUsage' here. The evidence record does
-- have somewhere to say it, and says it: see 'observeClaudeCli'.
reportedUsage :: Internal.ClaudeCliReport -> Usage
reportedUsage r = fromMaybe zeroUsage (r ^. #usage)

millisBetween :: UTCTime -> UTCTime -> Int
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))

exceptionToError :: SomeException -> BaikaiError
exceptionToError e = fromMaybe (providerError (Text.pack (displayException e))) (fromException e)
