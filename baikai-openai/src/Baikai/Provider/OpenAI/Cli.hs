-- | Provider that drives the @codex exec --json@ non-interactive CLI
-- as a subprocess.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.OpenAICompletionsCli' handler with default config.
-- 'registerWith' accepts a caller-supplied 'CodexCliConfig'.
module Baikai.Provider.OpenAI.Cli
  ( CodexCliConfig,
    executable,
    extraArgs,
    workingDir,
    skipGitRepoCheck,
    ephemeral,
    codexCliCommand,
    codexCliPrompt,
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
import Baikai.ThinkingLevel (renderThinkingLevel)
import Baikai.Usage (zeroUsage)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeAsyncException (..), SomeException, displayException, fromException, throwIO, try)
import Control.Lens ((^.))
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
      complete = runCodexCli cfg
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
  Just lvl -> ["-c", "model_reasoning_effort=" <> Text.unpack (renderThinkingLevel lvl)]

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
  let mkEv end st =
        Build.minimalEvidence
          m
          opts
          Ev.TransportSubprocess
          Ev.noThinkingRequested
          (Internal.argvEnvelope exe args)
          start
          end
          st
  result <- trySync (P.withCreateProcess procSpec (consume start mkEv m))
  case result of
    Right resp -> pure resp
    Left ex -> do
      end <- getCurrentTime
      ev <- mkEv end Ev.CallFailed
      let resp = Resp.errorResponse m end (millisBetween start end) (exceptionToError ex)
      pure resp {Resp.evidence = ev}

consume ::
  UTCTime ->
  (UTCTime -> Ev.CallStatus -> IO (Maybe Ev.ModelCallEvidence)) ->
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
      body <- Internal.parseCodexJsonlStream (handleStream hOut)
      errBytes <- takeMVar errVar
      exitCode <- P.waitForProcess ph
      end <- getCurrentTime
      case exitCode of
        ExitFailure n -> do
          ev <- mkEv end Ev.CallFailed
          let resp =
                Resp.errorResponse
                  m
                  end
                  (millisBetween start end)
                  (processError n (Internal.decodeUtf8Lenient errBytes))
          pure resp {Resp.evidence = ev}
        ExitSuccess -> do
          ev <- mkEv end Ev.CallSucceeded
          pure
            Resp.Response
              { Resp.message =
                  AssistantPayload
                    { content =
                        Vector.singleton (AssistantText (TextContent (Text.strip body))),
                      usage = zeroUsage,
                      stopReason = Stop,
                      errorMessage = Nothing,
                      timestamp = Just end
                    },
                Resp.model = m,
                Resp.api = OpenAICompletionsCli,
                Resp.provider = m ^. #provider,
                Resp.responseId = Nothing,
                Resp.latencyMs = millisBetween start end,
                Resp.errorInfo = Nothing,
                Resp.evidence = ev
              }
  where
    errorNow err = do
      end <- getCurrentTime
      ev <- mkEv end Ev.CallFailed
      let resp = Resp.errorResponse m end (millisBetween start end) err
      pure resp {Resp.evidence = ev}

millisBetween :: UTCTime -> UTCTime -> Int
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))

trySync :: IO a -> IO (Either SomeException a)
trySync action = do
  r <- try action
  case r of
    Left e
      | Just (SomeAsyncException _) <- (fromException e :: Maybe SomeAsyncException) ->
          throwIO e
      | otherwise -> pure (Left e)
    Right a -> pure (Right a)

exceptionToError :: SomeException -> BaikaiError
exceptionToError e = fromMaybe (providerError (Text.pack (displayException e))) (fromException e)
