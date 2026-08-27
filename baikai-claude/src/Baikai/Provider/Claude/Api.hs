-- | Provider wrapping the @claude@ package's Messages API.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.AnthropicMessages' handler into the baikai provider
-- registry. After registration, any 'Baikai.Model.Model' whose
-- 'Baikai.Api.api' tag is 'AnthropicMessages' dispatches through
-- this handler.
--
-- The handler resolves 'Baikai.Options.apiKey' when present, falling
-- back to the host-specific env var from
-- 'Baikai.Auth.defaultApiKeyEnvForBaseUrl'. Unknown hosts require an
-- explicit key source.
--
-- Streaming is the primary entry point. The handler exposes a
-- 'streamly' 'Stream' of 'AssistantMessageEvent' values bridged from a
-- local SSE transport that preserves HTTP status, headers, and body for
-- error classification. The synchronous @complete@ field is derived via
-- 'Baikai.Stream.streamingComplete', so callers that drain the stream
-- get the same fully-assembled 'Baikai.Response.Response'.
--
-- The machinery behind these three names — the transport driver seam,
-- the assembler and the event translator — lives in
-- "Baikai.Provider.Claude.Internal.Stream", which carries no stability
-- guarantees.
module Baikai.Provider.Claude.Api
  ( register,
    claudeMessagesProvider,
    claudeMessagesStream,
  )
where

import Baikai.Api (Api (..))
import Baikai.Context (Context)
import Baikai.Evidence qualified as Ev
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider (ApiProvider, apiProvider)
import Baikai.Provider.Claude.Internal.Request (describeThinkingFor)
import Baikai.Provider.Claude.Internal.Stream (claudeMessagesStreamWith, liveSseDriver)
import Baikai.Provider.Registry (registerApiProvider)
import Baikai.Stream.Event (AssistantMessageEvent)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Streamly.Data.Stream (Stream)

-- | Install the Anthropic Messages handler into the registry.
-- Calling 'register' twice keeps only the second handler — the
-- registry's insert-overwrites semantic.
register :: IO ()
register = registerApiProvider claudeMessagesProvider

-- | First-class Anthropic Messages provider value. Use with
-- 'Baikai.Provider.registerApiProviderWith' or
-- 'Baikai.Provider.newProviderRegistryFrom' for explicit registries.
claudeMessagesProvider :: ApiProvider
claudeMessagesProvider =
  apiProvider AnthropicMessages claudeMessagesStream
    -- 'describeThinkingFor' is the same function 'mapRequest' uses, so
    -- the gate's answer and the wire's behaviour cannot disagree.
    & #describeThinking .~ describeThinkingFor
    & #strengthCeiling .~ Ev.declaredStrength AnthropicMessages

-- | Streaming producer for the Anthropic Messages API.
--
-- Forks one worker thread per call that drives the local Claude SSE
-- transport, pushing classified errors and typed
-- 'Claude.V1.Messages.MessageStreamEvent' values onto a bounded
-- 'Baikai.Provider.Internal.StreamWorker.FrameQueue'. The returned
-- 'Stream' is a translator: it pulls raw events off that queue and emits
-- zero or more 'AssistantMessageEvent' values per upstream event,
-- beginning with exactly one 'Baikai.Stream.Event.EventStart' and
-- terminating with exactly one 'Baikai.Stream.Event.EventDone' or
-- 'Baikai.Stream.Event.EventError'.
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
--
-- Producer-side exceptions (HTTP failure, decode failure inside the
-- SDK, etc.) are caught and re-encoded into an
-- 'Baikai.Stream.Event.EventError' carrying whatever content was already
-- assembled — the "partial output is always recoverable" promise.
claudeMessagesStream ::
  Model -> Context -> Options -> Stream IO AssistantMessageEvent
claudeMessagesStream = claudeMessagesStreamWith liveSseDriver
