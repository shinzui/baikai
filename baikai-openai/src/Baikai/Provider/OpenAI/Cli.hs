-- | Provider that drives the @codex exec --json@ non-interactive CLI
-- as a subprocess.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.OpenAICompletionsCli' handler with default config.
-- Register @codexCliProvider cfg@ to supply a caller-supplied
-- 'CodexCliConfig'.
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
--
-- Structured output: a 'Baikai.ResponseFormat.JsonSchema' in
-- 'Baikai.Options.responseFormat' is written, as UTF-8 JSON bytes, to a
-- temporary file passed as @--output-schema <file>@; the file is removed
-- when the call ends, however it ends. The response text is the final
-- agent message, which the tool has constrained to the schema. Codex
-- submits the schema in strict mode, so it must satisfy OpenAI's strict
-- rules (for example @additionalProperties: false@). An installed
-- @codex@ too old to know the flag yields an 'Baikai.Error.InvalidRequest'
-- error carrying the exit code, never unconstrained text.
-- 'Baikai.ResponseFormat.JsonObject' and the schema's @name@ and
-- @strict@ have no CLI analogue and are not forwarded.
module Baikai.Provider.OpenAI.Cli
  ( CodexCliConfig,
    executable,
    extraArgs,
    workingDir,
    skipGitRepoCheck,
    ephemeral,
    codexCliCommand,
    codexCliCommandWith,
    codexCliPrompt,
    codexCliThinking,
    defaultCodexCliConfig,
    codexCliProvider,
    register,
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
    apiProviderWith,
    registerApiProvider,
  )
import Baikai.Response qualified as Resp
import Baikai.ResponseFormat (ResponseFormat (..), declaredStructuredOutput)
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
import Baikai.ThinkingLevel (ThinkingLevel, renderThinkingLevel)
import Baikai.Usage (Usage, zeroUsage)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, SomeException, bracket, displayException, fromException, try)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, openBinaryTempFile)
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
--
-- The Codex binary runs in batch mode. @stream@ wraps the batch
-- output in a synthetic one-shot event stream
-- (@EventStart, TextStart 0, TextDelta 0 body, TextEnd 0, EventDone@)
-- emitted after the subprocess exits. @complete@ stays on the
-- direct batch path so it preserves 'Baikai.Response.latencyMs' rather
-- than recomputing it from synthetic event timestamps.
codexCliProvider :: CodexCliConfig -> ApiProvider
codexCliProvider cfg =
  apiProviderWith
    OpenAICompletionsCli
    (liftCompleteToStream (runCodexCli cfg))
    (runCodexCli cfg)
    -- The model plays no part: this transport's only reasoning
    -- control is a command-line flag derived from Options alone.
    & #describeThinking .~ (\_ opts -> codexCliThinking opts)
    & #strengthCeiling .~ Ev.declaredStrength OpenAICompletionsCli
    & #structuredOutput .~ declaredStructuredOutput OpenAICompletionsCli

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
--
-- This never renders @--output-schema@, even when
-- 'Baikai.Options.responseFormat' carries a schema: the schema file
-- exists only while a call runs, so a pure renderer has no path to
-- name. Use 'codexCliCommandWith' to see the vector a schema call
-- spawns.
codexCliCommand :: CodexCliConfig -> Model -> Context -> Options -> (FilePath, [String])
codexCliCommand cfg = codexCliCommandWith cfg Nothing

-- | 'codexCliCommand' with the schema file to pass as
-- @--output-schema@, rendered after the reasoning-effort override and
-- before 'extraArgs'. 'Nothing' renders exactly 'codexCliCommand'.
codexCliCommandWith ::
  CodexCliConfig -> Maybe FilePath -> Model -> Context -> Options -> (FilePath, [String])
codexCliCommandWith cfg schemaFile m ctx opts =
  ( cfg ^. #executable,
    ["exec"]
      <> modelArgs m
      <> ["--json"]
      <> ["--skip-git-repo-check" | cfg ^. #skipGitRepoCheck]
      <> ["--ephemeral" | cfg ^. #ephemeral]
      <> effortArgs opts
      <> maybe [] (\path -> ["--output-schema", path]) schemaFile
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
            displayText = Nothing,
            adjustments = [Ev.EffortClamped lvl wire | wire /= renderThinkingLevel lvl]
          }

-- | The schema a caller asked the tool to enforce, if any.
requestedSchema :: Options -> Maybe Aeson.Value
requestedSchema opts = case opts ^. #responseFormat of
  Just (JsonSchema f) -> Just (f ^. #schema)
  _ -> Nothing

-- | Write the schema to a fresh temporary file for the duration of one
-- action, and remove it afterwards however the action ends.
--
-- The bytes come from 'Aeson.encode', which is UTF-8 by construction;
-- nothing here goes through a locale-dependent text handle. A failure
-- to remove the file is ignored: the call's outcome is already decided,
-- and a stray file in the temporary directory is harmless.
withSchemaFile :: Aeson.Value -> (FilePath -> IO a) -> IO a
withSchemaFile schemaDoc k = do
  dir <- getTemporaryDirectory
  bracket
    (openBinaryTempFile dir "baikai-codex-schema.json")
    (\(path, h) -> hClose h >> void (try (removeFile path) :: IO (Either IOException ())))
    ( \(path, h) -> do
        LBS.hPut h (Aeson.encode schemaDoc)
        hClose h
        k path
    )

compactJson :: Aeson.Value -> String
compactJson = Text.unpack . Internal.decodeUtf8Lenient . LBS.toStrict . Aeson.encode

runCodexCli :: CodexCliConfig -> Model -> Context -> Options -> IO Resp.Response
runCodexCli cfg m ctx opts = do
  let schema = requestedSchema opts
      -- The envelope names the schema itself where the spawned vector
      -- names its temporary file: the random path would make the
      -- request commitment unreproducible, and the schema is what
      -- actually crossed the boundary.
      (exe, args) = codexCliCommandWith cfg (compactJson <$> schema) m ctx opts
      procSpec schemaFile =
        (P.proc exe (snd (codexCliCommandWith cfg schemaFile m ctx opts)))
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
      launch schemaFile =
        P.withCreateProcess (procSpec schemaFile) (consume start mkEv (isJust schema) m)
  -- Writing the schema file sits inside 'Internal.trySync' too, so a
  -- temporary directory that cannot be written becomes an error-shaped
  -- response rather than an exception escaping the provider.
  result <-
    Internal.trySync $ case schema of
      Nothing -> launch Nothing
      Just schemaDoc -> withSchemaFile schemaDoc (launch . Just)
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
  -- | Whether @--output-schema@ was sent.
  Bool ->
  Model ->
  Maybe Handle ->
  Maybe Handle ->
  Maybe Handle ->
  P.ProcessHandle ->
  IO Resp.Response
consume start mkEv schemaSent m _ mOut mErr ph = do
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
          let stderr = Internal.decodeUtf8Lenient errBytes
              flagRejected
                | schemaSent = Internal.unsupportedFlagError "codex" "--output-schema" n stderr
                | otherwise = Nothing
              err = fromMaybe (processError n stderr) flagRejected
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
