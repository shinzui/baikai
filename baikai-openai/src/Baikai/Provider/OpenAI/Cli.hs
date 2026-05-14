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
-- The provider always returns 'Baikai.Response.Response' with
-- @usage = Nothing@ and @cost = Nothing@.
module Baikai.Provider.OpenAI.Cli
  ( CodexCli
  , CodexCliConfig (..)
  , defaultCodexCliConfig
  , codexCli
  ) where

import Baikai.Error (BaikaiError (..))
import qualified Baikai.Model as Model
import Baikai.Provider (Provider (..))
import qualified Baikai.Provider.Cli.Internal as Internal
import qualified Baikai.Request as Req
import qualified Baikai.Response as Resp
import Control.Exception (bracket, throwIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import GHC.Generics (Generic)
import Streamly.Data.Stream (Stream)
import qualified Streamly.Data.Stream as Stream
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose)
import qualified System.Process as P

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
          { Resp.content = Text.strip body
          , Resp.model = req ^. #model
          , Resp.usage = Nothing
          , Resp.cost = Nothing
          , Resp.provider = "openai.codex.cli"
          , Resp.latencyMs = millisBetween start end
          }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
