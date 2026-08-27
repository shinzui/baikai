-- | A small, provider-neutral embeddings client over an OpenAI-compatible
-- @\/v1\/embeddings@ endpoint (EP-15).
--
-- baikai shipped no embeddings client; this is the first. It reuses the
-- @openai@ SDK's 'OpenAI.V1.makeMethods' and the sibling
-- 'OpenAI.V1.createEmbeddings' method, baikai's own 'Baikai.Auth' for key
-- resolution — the same per-host table the chat providers use — and
-- baikai's own 'Baikai.Http' connection cache, which the chat providers
-- share, so two calls to one host reuse one TLS manager rather than
-- allocating one per call as the SDK's own @getClientEnv@ does.
--
-- It is policy-free (a plain @IO@ client, no effect binding) — the effect
-- interpreter lives one layer up in shikumi, exactly as @baikai-effectful@
-- relates to the transport.
--
-- An embedding model is named by a bare provider model-id string (e.g.
-- @\"text-embedding-3-small\"@) plus a base URL inside 'EmbeddingModel'; there is
-- no @Api@ tag and no chat-catalog entry, because none of the chat 'Baikai.Model'
-- fields (context window, output tokens, chat pricing, modalities) are meaningful
-- for embeddings.
module Baikai.Embedding
  ( EmbeddingModel (modelId, baseUrl, dimensions, apiKey),
    emptyEmbeddingModel,
    openAIEmbeddingModel,
    mkEmbeddingRequest,
    firstEmbedding,
    resolveEmbeddingKey,
    embeddingClientEnv,
    embed,
    embedOne,
  )
where

import Baikai.Auth (ApiKeySource (..), resolveApiKey)
import Baikai.Auth qualified as Auth
import Baikai.Error (BaikaiError, authError, decodeError, invalidRequest)
import Baikai.Http qualified as Http
import Baikai.Url qualified as Url
import Control.Exception (throwIO)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import OpenAI.V1 qualified as OpenAI
import OpenAI.V1.Embeddings qualified as Emb
import OpenAI.V1.Models qualified as OpenAIModels
import Servant.Client qualified as Client

-- | How to reach an embeddings endpoint and which model to ask for.
--
-- Construction: the constructor is deliberately not exported. Start
-- from 'emptyEmbeddingModel' (or 'openAIEmbeddingModel') and override
-- fields by record update.
data EmbeddingModel = EmbeddingModel
  { -- | e.g. @\"text-embedding-3-small\"@
    modelId :: !Text,
    -- | e.g. @\"https:\/\/api.openai.com\"@ (empty = the OpenAI default)
    baseUrl :: !Text,
    -- | request a reduced dimensionality, or 'Nothing' for the model default
    dimensions :: !(Maybe Natural),
    -- | How to resolve the API key (from "Baikai.Auth"). 'Nothing' means
    -- the conventional variable for this host, from
    -- 'Auth.defaultApiKeyEnvForBaseUrl' — the same table the chat
    -- providers consult — and a host that table does not know refuses
    -- with an 'Baikai.Error.AuthError' rather than falling back to
    -- another provider's credential. This mirrors
    -- 'Baikai.Options.apiKey', which has meant exactly that all along.
    apiKey :: !(Maybe ApiKeySource)
  }
  deriving stock (Eq, Show, Generic)

-- | A blank embedding model; a record-update target for hand-built models. Keyed
-- per host by default, so @api.openai.com@ resolves @OPENAI_API_KEY@ and
-- @api.deepseek.com@ resolves @DEEPSEEK_API_KEY@.
emptyEmbeddingModel :: EmbeddingModel
emptyEmbeddingModel =
  EmbeddingModel
    { modelId = "",
      baseUrl = "",
      dimensions = Nothing,
      apiKey = Nothing
    }

-- | The OpenAI default: @api.openai.com@, whose conventional key variable is
-- @OPENAI_API_KEY@, and model-default dimensionality.
openAIEmbeddingModel :: Text -> EmbeddingModel
openAIEmbeddingModel mid =
  emptyEmbeddingModel
    { modelId = mid,
      baseUrl = "https://api.openai.com",
      dimensions = Nothing,
      apiKey = Nothing
    }

-- | Build the OpenAI @\/v1\/embeddings@ request for a single input text. Pure and
-- exported so it can be unit-tested without a network. (@embed@ calls it.)
mkEmbeddingRequest :: EmbeddingModel -> Text -> Emb.CreateEmbeddings
mkEmbeddingRequest m t =
  Emb._CreateEmbeddings
    { Emb.input = t,
      Emb.model = OpenAIModels.Model (modelId m),
      Emb.dimensions = dimensions m
    }

-- | Extract the first embedding vector from an SDK response. OpenAI's
-- embeddings endpoint normally returns one item per input, but a malformed or
-- compatible endpoint can return an empty @data@ array. Treat that as a typed
-- decode failure instead of indexing the empty vector.
firstEmbedding :: Vector Emb.EmbeddingObject -> Either BaikaiError (Vector Double)
firstEmbedding objs =
  case V.uncons objs of
    Nothing ->
      Left (decodeError "embeddings response contained no data")
    Just (obj, _) ->
      Right (Emb.embedding obj)

-- | The key 'embed' will send: the explicit source when the model names
-- one, otherwise the conventional variable for the model's host.
--
-- A host with no conventional variable is an 'Baikai.Error.AuthError'
-- naming the host and telling the caller to set the field, rather than a
-- silent fallback to @OPENAI_API_KEY@ — which is what this did before,
-- and which sent an OpenAI key to whatever host the base URL named.
--
-- Exported so a caller can see which key a model resolves without
-- making a request.
resolveEmbeddingKey :: EmbeddingModel -> IO Text
resolveEmbeddingKey m = case apiKey m of
  Just source -> resolveApiKey source
  Nothing -> case Auth.defaultApiKeyEnvForBaseUrl url of
    Just name -> resolveApiKey (ApiKeyEnv name)
    Nothing ->
      throwIO
        ( authError
            ( "no default API key env is known for "
                <> url
                <> "; set EmbeddingModel.apiKey explicitly"
            )
        )
  where
    url = urlOf m

-- | The cached connection 'embed' will use, from "Baikai.Http" — the
-- same process-global cache the chat providers use, so an embeddings
-- call and a chat call to one host share a TLS manager.
--
-- Exported so the sharing is observable without a network call.
embeddingClientEnv :: EmbeddingModel -> IO Client.ClientEnv
embeddingClientEnv = Http.getClientEnvCached . urlOf

-- | Embed a batch of texts: one vector per input text, in input order. The SDK's
-- @CreateEmbeddings.input@ is a single 'Text', so this loops one call per text. The
-- transport exception (a Servant client error) is let propagate — error remapping
-- is the consumer's job (in shikumi the interpreter wraps it as a typed error).
embed :: EmbeddingModel -> [Text] -> IO (Vector (Vector Double))
embed _ [] = pure V.empty
embed m texts = do
  -- Checked before the key is resolved, so a base URL baikai will not
  -- send to never causes a credential to be read out of the
  -- environment. The base URL is the API root — baikai appends
  -- @\/v1\/embeddings@ itself, and a trailing @\/v1@ is removed rather
  -- than doubled.
  case Url.baseUrlProblem (urlOf m) of
    Just problem ->
      throwIO (invalidRequest ("EmbeddingModel.baseUrl is not usable: " <> problem))
    Nothing -> pure ()
  key <- resolveEmbeddingKey m
  env <- embeddingClientEnv m
  let create = OpenAI.createEmbeddings (OpenAI.makeMethods env key Nothing Nothing)
  V.fromList <$> traverse (embedText create) texts
  where
    embedText create t = do
      objs <- create (mkEmbeddingRequest m t)
      either throwIO pure (firstEmbedding objs)

-- | Embed a single text.
embedOne :: EmbeddingModel -> Text -> IO (Vector Double)
embedOne m t = do
  vs <- embed m [t]
  case V.uncons vs of
    Just (v, _) -> pure v
    Nothing -> throwIO (decodeError "embedding batch unexpectedly returned no vectors")

-- | Substitute the OpenAI default for an empty base URL (as the chat provider does).
urlOf :: EmbeddingModel -> Text
urlOf m = case baseUrl m of
  "" -> "https://api.openai.com"
  u -> u
