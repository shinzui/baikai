-- | Provider that drives the @codex exec --json@ non-interactive CLI as a
-- subprocess.
--
-- Construct a 'CodexCli' with 'codexCli' and the desired 'CodexCliConfig'
-- (or just 'defaultCodexCliConfig'), then call 'Baikai.Provider.runRequest'
-- like any other provider. The provider name is @"openai.codex.cli"@.
--
-- Stdout is consumed as a streamly byte stream, split on newlines, decoded as
-- JSON, and folded to the concatenation of all @agent_message@ payloads. The
-- subprocess handle is guarded by 'bracket' so it is reaped on any exception.
-- The provider always returns 'Baikai.Response.Response' whose embedded
-- assistant message carries zero token counts (and therefore zero cost).
module Baikai.Provider.OpenAI.Cli
  ( CodexCli
  , CodexCliConfig (..)
  , defaultCodexCliConfig
  , codexCli
  ) where

import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Error (BaikaiError (..))
import Baikai.Message (Message (..))
import Baikai.Model qualified as Model
import Baikai.Provider (Provider (..))
import Baikai.Provider.Cli.Internal qualified as Internal
import Baikai.Request qualified as Req
import Baikai.Response qualified as Resp
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (_Usage)
import Control.Exception (bracket, throwIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose)
import System.Process qualified as P

-- | Configuration for the @codex exec --json@ subprocess.
--
-- 'executable' defaults to the bare string @"codex"@ so the OS resolves the
-- binary via @PATH@. 'skipGitRepoCheck' and 'ephemeral' default to 'True' so
-- the CLI does not refuse to run outside a Git repo and does not write a
-- session file to disk. 'extraArgs' are appended verbatim before the prompt.
data CodexCliConfig = CodexCliConfig
  { executable :: !FilePath
  , extraArgs :: !(Vector Text)
  , workingDir :: !(Maybe FilePath)
  , skipGitRepoCheck :: !Bool
  , ephemeral :: !Bool
  }
  deriving stock (Eq, Show, Generic)

defaultCodexCliConfig :: CodexCliConfig
defaultCodexCliConfig =
  CodexCliConfig
    { executable = "codex"
    , extraArgs = mempty
    , workingDir = Nothing
    , skipGitRepoCheck = True
    , ephemeral = True
    }

-- | A configured Codex CLI provider. Holding a value of this type does not
-- spawn any processes; the subprocess is only spawned on 'runRequest'.
newtype CodexCli = CodexCli {config :: CodexCliConfig}
  deriving stock (Eq, Show, Generic)

codexCli :: MonadIO m => CodexCliConfig -> m CodexCli
codexCli = pure . CodexCli

-- | Emit @--model M@ unless 'Req.Request.model' is empty, in which case the
-- CLI's built-in default is used. Empty is the sentinel because the unified
-- 'Baikai.Model.Model' newtype wraps 'Text' and a blank value is the
-- least-surprising "don't override" signal for CLI providers.
modelArgs :: Req.Request -> [String]
modelArgs req = case Text.strip (Model.unModel (req ^. #model)) of
  "" -> []
  m -> ["--model", Text.unpack m]

-- | Read a handle as a streamly stream of small ByteString chunks. Reading
-- stops when 'BS.hGetSome' returns an empty chunk, which signals EOF after
-- the child closes its stdout.
handleStream :: Handle -> Stream IO BS.ByteString
handleStream h = Stream.unfoldrM step ()
  where
    step _ = do
      chunk <- BS.hGetSome h 4096
      if BS.null chunk
        then pure Nothing
        else pure (Just (chunk, ()))

instance Provider CodexCli where
  providerName _ = "openai.codex.cli"
  runRequest (CodexCli cfg) req = liftIO $ do
    let prompt = Internal.renderPrompt req
        baseArgs =
          ["exec"]
            <> modelArgs req
            <> ["--json"]
            <> [ "--skip-git-repo-check"
               | cfg ^. #skipGitRepoCheck
               ]
            <> ["--ephemeral" | cfg ^. #ephemeral]
            <> fmap Text.unpack (Vector.toList (cfg ^. #extraArgs))
            <> [Text.unpack prompt]
        procSpec =
          (P.proc (cfg ^. #executable) baseArgs)
            { P.std_in = P.NoStream
            , P.std_out = P.CreatePipe
            , P.std_err = P.CreatePipe
            , P.cwd = cfg ^. #workingDir
            }
    start <- getCurrentTime
    bracket
      (P.createProcess procSpec)
      cleanup
      (consume start req)

cleanup :: (Maybe Handle, Maybe Handle, Maybe Handle, P.ProcessHandle) -> IO ()
cleanup (_, mOut, mErr, ph) = do
  maybe (pure ()) hClose mOut
  maybe (pure ()) hClose mErr
  P.terminateProcess ph

consume ::
  UTCTime ->
  Req.Request ->
  (Maybe Handle, Maybe Handle, Maybe Handle, P.ProcessHandle) ->
  IO Resp.Response
consume start req (_, mOut, mErr, ph) = do
  hOut <- maybe (throwIO (ProviderError "codex: stdout handle missing")) pure mOut
  hErr <- maybe (throwIO (ProviderError "codex: stderr handle missing")) pure mErr
  body <- Internal.parseCodexJsonlStream (handleStream hOut)
  errBytes <- BS.hGetContents hErr
  exitCode <- P.waitForProcess ph
  end <- getCurrentTime
  case exitCode of
    ExitFailure n -> throwIO (ProcessError n (Internal.decodeUtf8Lenient errBytes))
    ExitSuccess ->
      pure
        Resp.Response
          { Resp.message =
              AssistantMessage
                { assistantContent =
                    Vector.singleton (AssistantText (TextContent (Text.strip body)))
                , usage = _Usage
                , stopReason = Stop
                , errorMessage = Nothing
                , timestamp = end
                }
          , Resp.model = req ^. #model
          , Resp.api = "openai.codex.cli"
          , Resp.provider = "openai.codex.cli"
          , Resp.responseId = Nothing
          , Resp.latencyMs = millisBetween start end
          }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
