-- | Free names the capability Shape blocks refer to. Every value is an
-- @error@ thunk: the blocks are compiled to prove they type-check against
-- the current exports and are never run, because running one would need
-- a provider. Add a fixture when a new block needs one; never make one
-- do anything.
module Shape.Fixtures
  ( model,
    modelWithCliTag,
    ctx,
    opts,
    registry,
    dispatcher,
    getTimeTool,
    personSchema,
    tracer,
    request,
    config,
    reportRefusal,
    reportFailure,
    backOff,
    retry,
    giveUp,
    use,
    step,
    initial,
  )
where

import Baikai.Agent (AgentRunRequest)
import Baikai.Content (ToolCall)
import Baikai.Context (Context)
import Baikai.Message (ToolResult)
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Claude.Agent (ClaudeAgentConfig)
import Baikai.Provider.Registry (ProviderRegistry)
import Baikai.Response (Response)
import Baikai.Stream.Event (AssistantMessageEvent)
import Baikai.Tool (Tool)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import OpenTelemetry.Trace.Core qualified as Otel

fixture :: String -> a
fixture name = error ("doc shape fixture " <> name <> " is never evaluated")

model :: Model
model = fixture "model"

modelWithCliTag :: Model
modelWithCliTag = fixture "modelWithCliTag"

ctx :: Context
ctx = fixture "ctx"

opts :: Options
opts = fixture "opts"

registry :: ProviderRegistry
registry = fixture "registry"

dispatcher :: ToolCall -> IO ToolResult
dispatcher = fixture "dispatcher"

getTimeTool :: Tool
getTimeTool = fixture "getTimeTool"

personSchema :: Aeson.Value
personSchema = fixture "personSchema"

tracer :: Otel.Tracer
tracer = fixture "tracer"

request :: AgentRunRequest
request = fixture "request"

config :: ClaudeAgentConfig
config = fixture "config"

reportRefusal :: Text -> IO a
reportRefusal = fixture "reportRefusal"

reportFailure :: Text -> IO a
reportFailure = fixture "reportFailure"

backOff :: Maybe Int -> IO ()
backOff = fixture "backOff"

retry :: IO ()
retry = fixture "retry"

giveUp :: IO ()
giveUp = fixture "giveUp"

use :: Response -> IO ()
use = fixture "use"

step :: Int -> AssistantMessageEvent -> Int
step = fixture "step"

initial :: Int
initial = fixture "initial"
