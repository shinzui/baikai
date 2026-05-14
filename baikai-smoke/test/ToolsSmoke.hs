-- | Two-turn tool round-trip smoke: ask the model for the time,
-- assert it invoked the @get_time@ tool, feed a synthesised
-- timestamp back, and assert the second-turn final answer
-- references the timestamp.
--
-- Mirrors the exit-code/skip style of 'Smoke.runApiCase': skips
-- (returns 'False') when the relevant API key is absent; calls
-- 'System.Exit.exitFailure' on assertion failure so the wrapping
-- @main@ surfaces it as a test-suite failure.
module ToolsSmoke
  ( ApiCase (..)
  , runToolCase
  ) where

import Baikai
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Aeson ((.=))
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | The shape mirrors 'Main.ApiCase' from @Smoke.hs@; we re-declare
-- it locally so 'ToolsSmoke' has no dependency on the smoke
-- entry-point module's internals.
data ApiCase = ApiCase
  { caseLabel :: !String
  , caseEnvVars :: ![String]
  , caseModel :: !Model
  }

runToolCase :: ApiCase -> IO Bool
runToolCase ApiCase {caseLabel, caseEnvVars, caseModel} = do
  matched <- firstSetEnv caseEnvVars
  case matched of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] none of "
          <> show caseEnvVars
          <> " set; skipping tool round-trip "
          <> caseLabel
          <> "."
      pure False
    Just (envVar, key) -> do
      let getTime =
            _Tool
              { name = "get_time"
              , description = "Return the current UTC ISO-8601 timestamp."
              , parameters =
                  Aeson.object
                    [ "type" .= ("object" :: Text)
                    , "properties" .= Aeson.object []
                    , "required" .= ([] :: [Text])
                    ]
              }
          ctx0 =
            _Context
              & #messages
                .~ Vector.singleton
                  (user "What time is it? Use the get_time tool to find out.")
              & #tools .~ Vector.singleton getTime
          baseOpts =
            _Options
              & #maxTokens .~ Just 1024
              & #temperature .~ Just 0.0
              & #apiKey .~ Just (Text.pack key)
          -- Turn 1: force a tool call so the round-trip is
          -- deterministic. Turn 2: let the model speak freely (it
          -- must produce text, not another tool call).
          turn1Opts = baseOpts & #toolChoice .~ Just ToolChoiceRequired
          turn2Opts = baseOpts & #toolChoice .~ Nothing
      resp1 <- completeRequest caseModel ctx0 turn1Opts
      let blocks1 = flattenAssistantBlocks resp1
          toolCalls = [tc | AssistantToolCall tc <- Vector.toList blocks1]
      case toolCalls of
        [] -> do
          hPutStrLn stderr $
            "[baikai-smoke] tool round-trip failed for "
              <> caseLabel
              <> " via "
              <> envVar
              <> ": expected an AssistantToolCall block in turn 1; got blocks: "
              <> show blocks1
          exitFailure
        (tc : _) -> do
          when (tc ^. #name /= "get_time") $ do
            hPutStrLn stderr $
              "[baikai-smoke] tool round-trip "
                <> caseLabel
                <> ": expected tool name 'get_time'; got "
                <> show (tc ^. #name)
            exitFailure
          let timestamp = "2026-05-14T15:09:00Z" :: Text
          ctx1 <-
            appendToolResult ctx0 resp1 (\_ -> pure timestamp)
          resp2 <- completeRequest caseModel ctx1 turn2Opts
          let blocks2 = flattenAssistantBlocks resp2
              texts =
                [ t
                | AssistantText (TextContent t) <- Vector.toList blocks2
                ]
              -- The model may rewrite "2026-05-14T15:09:00Z" into
              -- prose ("May 14, 2026", "15:09 UTC", etc.). Accept
              -- any rendering that surfaces the year, a date
              -- fragment, or the time of day — that is enough to
              -- prove the tool result reached the model.
              mentions =
                any
                  ( \t ->
                      Text.isInfixOf "2026" t
                        || Text.isInfixOf "15:09" t
                        || Text.isInfixOf "May 14" t
                  )
                  texts
          when (not mentions) $ do
            hPutStrLn stderr $
              "[baikai-smoke] tool round-trip "
                <> caseLabel
                <> ": turn-2 final answer did not mention the timestamp. Texts: "
                <> show texts
            exitFailure
          hPutStrLn stderr $
            "[baikai-smoke] tool round-trip "
              <> caseLabel
              <> " ok via "
              <> envVar
              <> "; tool="
              <> show (tc ^. #name)
              <> ", final mentions timestamp"
          pure True

firstSetEnv :: [String] -> IO (Maybe (String, String))
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure $ case find (\(_, m) -> isJust m) results of
    Just (v, Just val) -> Just (v, val)
    _ -> Nothing
