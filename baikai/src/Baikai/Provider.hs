-- | The provider surface.
--
-- The prior 'Provider' typeclass and 'SomeProvider' existential are
-- removed. Dispatch now goes through 'Baikai.Provider.Registry':
-- the caller picks a 'Baikai.Model.Model' record and calls
-- 'completeRequest'; the registry looks up the right handler by the
-- model's 'Baikai.Api.Api' tag.
--
-- This module re-exports the registry surface so the
-- @import Baikai.Provider@ habit still resolves the symbols a
-- caller cares about.
module Baikai.Provider
  ( ApiProvider (apiTag, stream, complete, describeThinking, strengthCeiling),
    apiProvider,
    apiProviderWith,
    ProviderRegistry,
    newProviderRegistry,
    newProviderRegistryFrom,
    globalProviderRegistry,
    registerApiProviderWith,
    registerApiProvider,
    assertRegistered,
    lookupApiProviderWith,
    lookupApiProvider,
    completeRequestWith,
    completeRequest,
    runToolLoopWith,
    runToolLoop,
    completeText,
  )
where

import Baikai.Api (Api)
import Baikai.Context (Context)
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    apiProviderWith,
    assertRegistered,
    completeRequest,
    completeRequestWith,
    completeText,
    globalProviderRegistry,
    lookupApiProvider,
    lookupApiProviderWith,
    newProviderRegistry,
    newProviderRegistryFrom,
    registerApiProvider,
    registerApiProviderWith,
    runToolLoop,
    runToolLoopWith,
  )
import Baikai.Stream (streamingComplete)
import Baikai.Stream.Event (AssistantMessageEvent)
import Streamly.Data.Stream (Stream)

-- | Build an 'ApiProvider' from an 'Baikai.Api.Api' tag and a streaming
-- producer, deriving the synchronous @complete@ by draining that stream
-- with 'Baikai.Stream.streamingComplete'.
--
-- This is the documented construction path. The 'ApiProvider'
-- constructor is not exported, so a field added in a later release
-- cannot break a registration site: start here and override what you
-- need by record update.
--
-- > apiProvider (Custom "my-api") myStream
-- >   & #describeThinking .~ myDescribeThinking
apiProvider ::
  Api ->
  (Model -> Context -> Options -> Stream IO AssistantMessageEvent) ->
  ApiProvider
apiProvider tag producer = apiProviderWith tag producer (streamingComplete producer)
