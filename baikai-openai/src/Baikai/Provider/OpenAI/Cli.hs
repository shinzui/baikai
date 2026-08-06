-- | Provider that drives the @codex exec --json@ non-interactive CLI
-- as a subprocess.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.OpenAICompletionsCli' handler with default config.
-- 'registerWith' accepts a caller-supplied 'CodexCliConfig'.
--
-- The 'Response' this provider returns carries whatever the tool
-- reported about its own run: the token counts from the event stream's
-- turn-completion event, and the thread identifier from its
-- thread-start event as the response identifier. A tool that reports
-- neither yields zeroes and 'Nothing', which is an accurate record of
-- its silence rather than a claim that the call consumed nothing.
--
-- Evidence from this transport is deliberately weaker than from the
-- Chat Completions API. A tool that exits zero has demonstrated that
-- it ran, not which model served the request, so a successful exit
-- never raises the recorded 'Baikai.Evidence.EvidenceStrength' — see
-- 'Baikai.Provider.Cli.Internal.subprocessStrength'.
module Baikai.Provider.OpenAI.Cli
  ( CodexCliConfig,
    executable,
    extraArgs,
    workingDir,
    skipGitRepoCheck,
    ephemeral,
    codexCliCommand,
    codexCliPrompt,
    codexCliThinking,
    defaultCodexCliConfig,
    codexCliProvider,
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
import Baikai.ThinkingLevel (ThinkingLevel, renderThinkingLevel)
import Baikai.Usage (Usage, zeroUsage)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, fromException, try)
import Control.Lens ((&), (.~), (^.))
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import System.Exit (ExitCode (..))
import System.IO (Handle)
import System.Process qualified as P

-- | Configuration for the @codex exec --json@ subprocess.
data CodexCliConfig = CodexCliConfig
  { executable :: !FilePath,
    extraArgs :: ![Text],
    workingDir :: !(Maybe FilePath),
    skipGitRepoCheck :: !Bool,
    ephemeral :: !Bool
  }
  deriving stock (Eq, Show, Generic)

defaultCodexCliConfig :: CodexCliConfig
defaultCodexCliConfig =
  CodexCliConfig
    { executable = "codex",
      extraArgs = mempty,
      workingDir = Nothing,
      skipGitRepoCheck = True,
      ephemeral = True
    }

-- | Install the Codex CLI handler with 'defaultCodexCliConfig'.
register :: IO ()
register = registerApiProvider (codexCliProvider defaultCodexCliConfig)

-- | First-class Codex CLI provider value for a caller-supplied config.
codexCliProvider :: CodexCliConfig -> ApiProvider
codexCliProvider cfg =
  ApiProvider
    { apiTag = OpenAICompletionsCli,
      stream = liftCompleteToStream (runCodexCli cfg),
      complete = runCodexCli cfg,
      -- The model plays no part: this transport's only reasoning
      -- control is a command-line flag derived from Options alone.
      describeThinking = \_ opts -> codexCliThinking opts
    }

-- | Install the Codex CLI handler with a caller-supplied config.
--
-- The Codex binary runs in batch mode. 'stream' wraps the batch
-- output in a synthetic one-shot event stream
-- (@EventStart, TextStart 0, TextDelta 0 body, TextEnd 0, EventDone@)
-- emitted after the subprocess exits. 'complete' stays on the
-- direct batch path so it preserves 'Response.latencyMs' rather than
-- recomputing it from synthetic event timestamps. EP-3's Decision
-- Log records the deviation from "complete = streamingComplete .
-- stream".
registerWith :: CodexCliConfig -> IO ()
registerWith cfg = registerApiProvider (codexCliProvider cfg)
{-# DEPRECATED registerWith "use registerApiProvider (codexCliProvider cfg)" #-}

-- | Install the Codex CLI handler with 'defaultCodexCliConfig' into an explicit
-- registry.
registerWithRegistry :: ProviderRegistry -> IO ()
registerWithRegistry reg = registerWithRegistryAndConfig reg defaultCodexCliConfig
{-# DEPRECATED registerWithRegistry "use registerApiProviderWith reg (codexCliProvider defaultCodexCliConfig)" #-}

-- | Install the Codex CLI handler with a caller-supplied config into an
-- explicit registry.
registerWithRegistryAndConfig :: ProviderRegistry -> CodexCliConfig -> IO ()
registerWithRegistryAndConfig reg cfg =
  registerApiProviderWith
    reg
    (codexCliProvider cfg)
{-# DEPRECATED registerWithRegistryAndConfig "use registerApiProviderWith reg (codexCliProvider cfg)" #-}

modelArgs :: Model -> [String]
modelArgs m = case Text.strip (m ^. #modelId) of
  "" -> []
  mid -> ["--model", Text.unpack mid]

handleStream :: Handle -> Stream IO BS.ByteString
handleStream h = Stream.unfoldrM step ()
  where
    step _ = do
      chunk <- BS.hGetSome h 4096
      if BS.null chunk
        then pure Nothing
        else pure (Just (chunk, ()))

-- | The full prompt text passed to @codex exec@: the flattened
-- conversation, wrapped with the system prompt when one is set.
-- @codex exec --help@ exposes no system-prompt flag, so the system
-- prompt travels in prompt text.
codexCliPrompt :: Context -> Text
codexCliPrompt ctx =
  Internal.wrapSystemPrompt (ctx ^. #systemPrompt) (Internal.renderPrompt ctx)

-- | Render the executable and arguments for a @codex exec --json@
-- batch call. The prompt is preceded by @--@ so dash-leading prompts
-- cannot be parsed as options.
codexCliCommand :: CodexCliConfig -> Model -> Context -> Options -> (FilePath, [String])
codexCliCommand cfg m ctx opts =
  ( cfg ^. #executable,
    ["exec"]
      <> modelArgs m
      <> ["--json"]
      <> ["--skip-git-repo-check" | cfg ^. #skipGitRepoCheck]
      <> ["--ephemeral" | cfg ^. #ephemeral]
      <> effortArgs opts
      <> fmap Text.unpack (cfg ^. #extraArgs)
      <> ["--", Text.unpack (codexCliPrompt ctx)]
  )

-- | Render Codex's reasoning-effort config override from
-- 'Options.thinking'. Codex accepts all six Baikai levels verbatim;
-- when 'thinking' is unset, no override is emitted.
effortArgs :: Options -> [String]
effortArgs opts = case opts ^. #thinking of
  Nothing -> []
  Just lvl -> ["-c", "model_reasoning_effort=" <> Text.unpack (codexEffortValue lvl)]

-- | The word codex's @model_reasoning_effort@ override receives. Codex
-- accepts all six baikai levels verbatim, which makes this the identity
-- — and makes it the one transport in baikai that expresses every level
-- exactly.
codexEffortValue :: ThinkingLevel -> Text
codexEffortValue = renderThinkingLevel

-- | What the caller's reasoning-effort preference became on this
-- transport's command line.
--
-- The adjustment list is derived by comparing what 'effortArgs'
-- actually sends — through the same 'codexEffortValue' — with the
-- canonical level name, rather than being hardcoded empty. It is empty
-- today, but writing @[]@ by hand would keep claiming that after
-- someone changed the mapping, which is the class of silent divergence
-- this record exists to prevent.
codexCliThinking :: Options -> Ev.ThinkingTranslation
codexCliThinking opts = case opts ^. #thinking of
  Nothing -> Ev.noThinkingRequested
  Just lvl ->
    let wire = codexEffortValue lvl
     in Ev.ThinkingTranslation
          { requested = Just lvl,
            mode = Ev.ThinkingModeFlag,
            effortText = Just wire,
            budgetTokens = Nothing,
            wireField = Just "model_reasoning_effort",
            adjustments = [Ev.EffortClamped lvl wire | wire /= renderThinkingLevel lvl]
          }

runCodexCli :: CodexCliConfig -> Model -> Context -> Options -> IO Resp.Response
runCodexCli cfg m ctx opts = do
  let (exe, args) = codexCliCommand cfg m ctx opts
      procSpec =
        (P.proc exe args)
          { P.std_in = P.NoStream,
            P.std_out = P.CreatePipe,
            P.std_err = P.CreatePipe,
            P.cwd = cfg ^. #workingDir
          }
  start <- getCurrentTime
  -- The argument vector is the envelope: for a subprocess it is what
  -- crossed the boundary, and there is nothing else to describe the
  -- launch with. Built lazily and dropped unforced when the caller
  -- asked for no evidence.
  let mkEv mReport end st mErr = do
        prepared <-
          Build.minimalEvidence
            m
            opts
            Ev.TransportSubprocess
            (codexCliThinking opts)
            (Internal.argvEnvelope exe args)
            start
            end
            st
            mErr
        traverse (observeCodexCli exe mReport st) prepared
  result <- Internal.trySync (P.withCreateProcess procSpec (consume start mkEv m))
  case result of
    Right resp -> pure resp
    Left ex -> do
      end <- getCurrentTime
      let err = exceptionToError ex
      ev <- mkEv Nothing end Ev.CallFailed (Just err)
      let resp = Resp.errorResponse m end (millisBetween start end) err
      pure resp {Resp.evidence = ev}

consume ::
  UTCTime ->
  ( Maybe Internal.CodexRunReport ->
    UTCTime ->
    Ev.CallStatus ->
    Maybe BaikaiError ->
    IO (Maybe Ev.ModelCallEvidence)
  ) ->
  Model ->
  Maybe Handle ->
  Maybe Handle ->
  Maybe Handle ->
  P.ProcessHandle ->
  IO Resp.Response
consume start mkEv m _ mOut mErr ph = do
  case (mOut, mErr) of
    (Nothing, _) -> errorNow (providerError "codex: stdout handle missing")
    (_, Nothing) -> errorNow (providerError "codex: stderr handle missing")
    (Just hOut, Just hErr) -> do
      errVar <- newEmptyMVar
      _ <-
        forkIO $ do
          result <- try (BS.hGetContents hErr) :: IO (Either SomeException BS.ByteString)
          putMVar errVar (either (const BS.empty) id result)
      report <- Internal.parseCodexJsonlStream (handleStream hOut)
      errBytes <- takeMVar errVar
      exitCode <- P.waitForProcess ph
      end <- getCurrentTime
      case exitCode of
        ExitFailure n -> do
          let err = processError n (Internal.decodeUtf8Lenient errBytes)
          -- The event stream was drained before the exit status was
          -- known, so a failed run may still have named its thread and
          -- its token counts. Those are genuine observations and are
          -- kept; only the response commitment is withheld, because no
          -- complete response exists to commit to.
          ev <- mkEv (Just report) end Ev.CallFailed (Just err)
          let resp = Resp.errorResponse m end (millisBetween start end) err
          pure resp {Resp.evidence = ev, Resp.responseId = report ^. #threadId}
        ExitSuccess -> do
          ev <- mkEv (Just report) end Ev.CallSucceeded Nothing
          pure
            Resp.Response
              { Resp.message =
                  AssistantPayload
                    { content =
                        Vector.singleton
                          (AssistantText (TextContent (Text.strip (report ^. #message)))),
                      usage = reportedUsage report,
                      stopReason = Stop,
                      errorMessage = Nothing,
                      timestamp = Just end
                    },
                Resp.model = m,
                Resp.api = OpenAICompletionsCli,
                Resp.provider = m ^. #provider,
                Resp.responseId = report ^. #threadId,
                Resp.latencyMs = millisBetween start end,
                Resp.errorInfo = Nothing,
                Resp.evidence = ev
              }
  where
    errorNow err = do
      end <- getCurrentTime
      ev <- mkEv Nothing end Ev.CallFailed (Just err)
      let resp = Resp.errorResponse m end (millisBetween start end) err
      pure resp {Resp.evidence = ev}

-- | Fill in what the tool reported and what baikai knows about the
-- process it launched.
--
-- Only ever reached on a call whose caller asked for evidence, which is
-- what makes the version probe affordable here: it spawns a whole extra
-- subprocess, and charging that to a caller who only wanted an answer
-- from a tool they were about to run anyway would be a visible cost on
-- the cheapest possible call. The event-stream parsing it reads is the
-- opposite case and happens unconditionally, because the provider had
-- already decoded every event to find the assistant text.
--
-- Nothing here consults the request. A field the tool did not report
-- stays 'Ev.Unobserved' — which at @codex-cli 0.146.0@ includes the
-- model, because no event in its stream names one.
observeCodexCli ::
  FilePath ->
  Maybe Internal.CodexRunReport ->
  Ev.CallStatus ->
  Ev.ModelCallEvidence ->
  IO Ev.ModelCallEvidence
observeCodexCli exe mReport st ev = do
  identity <- Internal.executableIdentity exe
  let thread = observedOf (mReport >>= (^. #threadId))
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
      & #responseId .~ thread
      & #observedModel .~ reported
      & #usage .~ observedOf used
      & #responseCommitment .~ commitment used
      & #strength .~ Internal.subprocessStrength thread reported
  where
    commitment used = case (st, mReport) of
      (Ev.CallSucceeded, Just r) ->
        Ev.Observed
          ( Ev.commitmentDigest
              ( Internal.cliResponseEnvelope
                  (Text.strip (r ^. #message))
                  (fromMaybe zeroUsage used)
              )
          )
      _ -> Ev.Unobserved

observedOf :: Maybe a -> Ev.Observed a
observedOf = maybe Ev.Unobserved Ev.Observed

-- | The tool's own token counts, or zeroes when it reported none.
--
-- 'Resp.Response' has nowhere to say "the tool stayed silent", so a
-- silent tool still yields 'zeroUsage' here. The evidence record does
-- have somewhere to say it, and says it: see 'observeCodexCli'.
reportedUsage :: Internal.CodexRunReport -> Usage
reportedUsage r = fromMaybe zeroUsage (r ^. #usage)

millisBetween :: UTCTime -> UTCTime -> Int
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))

exceptionToError :: SomeException -> BaikaiError
exceptionToError e = fromMaybe (providerError (Text.pack (displayException e))) (fromException e)
