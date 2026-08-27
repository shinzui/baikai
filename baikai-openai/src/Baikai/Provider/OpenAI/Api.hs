-- | Provider wrapping the @openai@ package's Chat Completions API.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.OpenAIChatCompletions' handler into the baikai
-- provider registry. After registration, any 'Baikai.Model.Model'
-- whose 'Baikai.Api.api' tag is 'OpenAIChatCompletions' dispatches
-- through this handler.
--
-- The handler resolves 'Baikai.Options.apiKey' when present, falling
-- back to the host-specific env var from
-- 'Baikai.Auth.defaultApiKeyEnvForBaseUrl'. Unknown hosts require an
-- explicit key source.
--
-- Streaming is the primary entry point. The handler exposes a
-- 'streamly' 'Stream' of 'AssistantMessageEvent' values bridged from a
-- local SSE transport. The synchronous @complete@ field is derived via
-- 'Baikai.Stream.streamingComplete', so callers that drain the stream
-- get the same fully-assembled 'Baikai.Response.Response'.
--
-- The machinery behind these three names — the transport driver seam,
-- the chunk decoders, the reasoning-tag scanner, the assembler and the
-- usage mapping — lives in "Baikai.Provider.OpenAI.Internal.Stream",
-- which carries no stability guarantees.
module Baikai.Provider.OpenAI.Api
  ( register,
    openaiChatProvider,
    openaiChatStream,
  )
where

import Baikai.Api (Api (..))
import Baikai.Context (Context)
import Baikai.Evidence qualified as Ev
import Baikai.Model (Model, openaiCompletionsCompatFor)
import Baikai.Options (Options)
import Baikai.Provider (ApiProvider, apiProvider)
import Baikai.Provider.OpenAI.Internal.Stream (liveSseDriver, openaiChatStreamWith)
import Baikai.Provider.OpenAI.Shape (describeThinkingShape)
import Baikai.Provider.Registry (registerApiProvider)
import Baikai.Stream.Event (AssistantMessageEvent)
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Streamly.Data.Stream (Stream)

-- | Install the OpenAI Chat Completions handler into the registry.
register :: IO ()
register = registerApiProvider openaiChatProvider

-- | First-class OpenAI Chat Completions provider value. Use with
-- 'Baikai.Provider.registerApiProviderWith' or
-- 'Baikai.Provider.newProviderRegistryFrom' for explicit registries.
openaiChatProvider :: ApiProvider
openaiChatProvider =
  apiProvider OpenAIChatCompletions openaiChatStream
    -- Runs the real shaping function and keeps only its description, so
    -- the gate's answer and the wire's behaviour cannot disagree.
    & #describeThinking
      .~ ( \m opts ->
             describeThinkingShape (openaiCompletionsCompatFor m) (m ^. #reasoning) opts
         )
    & #strengthCeiling .~ Ev.declaredStrength OpenAIChatCompletions

-- | Streaming producer for the OpenAI Chat Completions API.
--
-- Forks one worker thread per call that drives the local
-- OpenAI-compatible SSE transport, pushing classified errors and decoded
-- chunk values onto a bounded
-- 'Baikai.Provider.Internal.StreamWorker.FrameQueue'. The consumer
-- translates each chunk into zero or more baikai
-- 'AssistantMessageEvent' values, beginning with exactly one
-- 'Baikai.Stream.Event.EventStart' and terminating with exactly one
-- 'Baikai.Stream.Event.EventDone' or 'Baikai.Stream.Event.EventError'.
--
-- The queue is bounded at
-- 'Baikai.Provider.Internal.StreamWorker.frameQueueCapacity' frames, so
-- a consumer that stops pulling stops the socket read after at most that
-- many further frames rather than letting the worker drain a whole
-- generation nobody will read.
--
-- The worker runs under a bracket, so the connection comes back
-- immediately when the stream ends normally or when an exception reaches
-- the draining thread (@Ctrl-C@, 'System.Timeout.timeout', @cancel@),
-- and at the next major garbage collection when a consumer simply
-- abandons the stream. "Baikai.Provider.Internal.StreamWorker" documents
-- why those three strengths differ and how a caller stops
-- deterministically.
openaiChatStream ::
  Model -> Context -> Options -> Stream IO AssistantMessageEvent
openaiChatStream = openaiChatStreamWith liveSseDriver
