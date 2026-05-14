-- | Provider that drives the @codex exec --json@ non-interactive CLI
-- as a subprocess.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.OpenAICompletionsCli' handler with default config.
-- 'registerWith' accepts a caller-supplied 'CodexCliConfig'.
module Baikai.Provider.OpenAI.Cli
  ( CodexCliConfig (..)
  , defaultCodexCliConfig
  , register
  , registerWith
  ) where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context)
import Baikai.Error (BaikaiError (..))
import Baikai.Message (Message (..))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Cli.Internal qualified as Internal
import Baikai.Provider.Registry (ApiProvider (..), registerApiProvider)
import Baikai.Stream (liftCompleteToStream)
import Baikai.Response qualified as Resp
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (_Usage)
import Control.Exception (bracket, throwIO)
import Control.Lens ((^.))
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

-- | Install the Codex CLI handler with 'defaultCodexCliConfig'.
register :: IO ()
register = registerWith defaultCodexCliConfig

-- | Install the Codex CLI handler with a caller-supplied config.
registerWith :: CodexCliConfig -> IO ()
registerWith cfg =
  registerApiProvider
    ApiProvider
      { apiTag = OpenAICompletionsCli
      , stream = liftCompleteToStream (runCodexCli cfg)
      , complete = runCodexCli cfg
      }

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

runCodexCli :: CodexCliConfig -> Model -> Context -> Options -> IO Resp.Response
runCodexCli cfg m ctx _opts = do
  let prompt = Internal.renderPrompt ctx
      baseArgs =
        ["exec"]
          <> modelArgs m
          <> ["--json"]
          <> ["--skip-git-repo-check" | cfg ^. #skipGitRepoCheck]
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
    (consume start m)

cleanup :: (Maybe Handle, Maybe Handle, Maybe Handle, P.ProcessHandle) -> IO ()
cleanup (_, mOut, mErr, ph) = do
  maybe (pure ()) hClose mOut
  maybe (pure ()) hClose mErr
  P.terminateProcess ph

consume
  :: UTCTime
  -> Model
  -> (Maybe Handle, Maybe Handle, Maybe Handle, P.ProcessHandle)
  -> IO Resp.Response
consume start m (_, mOut, mErr, ph) = do
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
          , Resp.model = m
          , Resp.api = OpenAICompletionsCli
          , Resp.provider = m ^. #provider
          , Resp.responseId = Nothing
          , Resp.latencyMs = millisBetween start end
          }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
