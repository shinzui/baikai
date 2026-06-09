-- | A small, provider-neutral embeddings client over an OpenAI-compatible
-- @\/v1\/embeddings@ endpoint (EP-15).
--
-- baikai shipped no embeddings client; this is the first. It reuses the same
-- @openai@ SDK path the OpenAI /chat/ provider already uses
-- ('OpenAI.V1.getClientEnv' + 'OpenAI.V1.makeMethods') and the sibling
-- 'OpenAI.V1.createEmbeddings' method, plus baikai's own 'Baikai.Auth' for key
-- resolution. It is policy-free (a plain @IO@ client, no effect binding) — the
-- effect interpreter lives one layer up in shikumi, exactly as @baikai-effectful@
-- relates to the transport.
--
-- An embedding model is named by a bare provider model-id string (e.g.
-- @\"text-embedding-3-small\"@) plus a base URL inside 'EmbeddingModel'; there is
-- no @Api@ tag and no chat-catalog entry, because none of the chat 'Baikai.Model'
-- fields (context window, output tokens, chat pricing, modalities) are meaningful
-- for embeddings.
module Baikai.Embedding
  ( EmbeddingModel (..),
    _EmbeddingModel,
    openAIEmbeddingModel,
    mkEmbeddingRequest,
    embed,
    embedOne,
  )
where

import Baikai.Auth (ApiKeySource (..), resolveApiKey)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Numeric.Natural (Natural)
import OpenAI.V1 qualified as OpenAI
import OpenAI.V1.Embeddings qualified as Emb
import OpenAI.V1.Models qualified as OpenAIModels

-- | How to reach an embeddings endpoint and which model to ask for.
data EmbeddingModel = EmbeddingModel
  { -- | e.g. @\"text-embedding-3-small\"@
    modelId :: !Text,
    -- | e.g. @\"https:\/\/api.openai.com\"@ (empty = the OpenAI default)
    baseUrl :: !Text,
    -- | request a reduced dimensionality, or 'Nothing' for the model default
    dimensions :: !(Maybe Natural),
    -- | how to resolve the API key (from "Baikai.Auth")
    apiKey :: !ApiKeySource
  }
  deriving stock (Show)

-- | A blank embedding model; a record-update target for hand-built models. Keyed
-- on @OPENAI_API_KEY@ by default.
_EmbeddingModel :: EmbeddingModel
_EmbeddingModel =
  EmbeddingModel
    { modelId = "",
      baseUrl = "",
      dimensions = Nothing,
      apiKey = ApiKeyEnv "OPENAI_API_KEY"
    }

-- | The OpenAI default: @api.openai.com@, key from @OPENAI_API_KEY@, model-default
-- dimensionality.
openAIEmbeddingModel :: Text -> EmbeddingModel
openAIEmbeddingModel mid =
  _EmbeddingModel
    { modelId = mid,
      baseUrl = "https://api.openai.com",
      dimensions = Nothing,
      apiKey = ApiKeyEnv "OPENAI_API_KEY"
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

-- | Embed a batch of texts: one vector per input text, in input order. The SDK's
-- @CreateEmbeddings.input@ is a single 'Text', so this loops one call per text. The
-- transport exception (a Servant client error) is let propagate — error remapping
-- is the consumer's job (in shikumi the interpreter wraps it as a typed error).
embed :: EmbeddingModel -> [Text] -> IO (Vector (Vector Double))
embed _ [] = pure V.empty
embed m texts = do
  key <- resolveApiKey (apiKey m)
  env <- OpenAI.getClientEnv (urlOf m)
  let create = OpenAI.createEmbeddings (OpenAI.makeMethods env key Nothing Nothing)
  V.fromList <$> traverse (embedText create) texts
  where
    embedText create t = do
      objs <- create (mkEmbeddingRequest m t)
      pure (Emb.embedding (V.head objs))

-- | Embed a single text.
embedOne :: EmbeddingModel -> Text -> IO (Vector Double)
embedOne m t = V.head <$> embed m [t]

-- | Substitute the OpenAI default for an empty base URL (as the chat provider does).
urlOf :: EmbeddingModel -> Text
urlOf m = case baseUrl m of
  "" -> "https://api.openai.com"
  u -> u
