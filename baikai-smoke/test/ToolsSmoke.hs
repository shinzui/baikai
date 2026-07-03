-- | Tool round-trip smoke: ask the model for the time, let
-- 'runToolLoop' execute the @get_time@ call, and assert the final
-- answer references the synthesised timestamp.
--
-- Mirrors the exit-code/skip style of 'Smoke.runApiCase': skips
-- (returns 'False') when the relevant API key is absent; calls
-- 'System.Exit.exitFailure' on assertion failure so the wrapping
-- @main@ surfaces it as a test-suite failure.
module ToolsSmoke
  ( ApiCase (..),
    runToolCase,
  )
where

import Baikai
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
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
  { caseLabel :: !String,
    caseEnvVars :: ![String],
    caseModel :: !Model
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
    Just (envVar, _key) -> do
      let getTime =
            _Tool
              { name = "get_time",
                description = "Return the current UTC ISO-8601 timestamp.",
                parameters =
                  Aeson.object
                    [ "type" .= ("object" :: Text),
                      "properties" .= Aeson.object [],
                      "required" .= ([] :: [Text])
                    ]
              }
          ctx0 =
            contextOf
              [user "What time is it? Use the get_time tool to find out."]
              & #tools .~ Vector.singleton getTime
          opts =
            _Options
              & #maxTokens .~ Just 1024
              & #temperature .~ Just 0.0
              -- Presence is checked above for skip/logging; resolution itself
              -- goes through the chain so provider code owns fallback order.
              & #apiKey .~ Just (ApiKeyEnvChain caseEnvVars)
          timestamp = "2026-05-14T15:09:00Z" :: Text
          dispatcher tc =
            if tc ^. #name == "get_time"
              then pure (toolResultText timestamp)
              else pure (toolResultErrorText ("unknown tool: " <> (tc ^. #name)))
      (ctx1, finalResp) <- runToolLoop 4 dispatcher caseModel ctx0 opts
      when (finalResp ^. #message ^. #stopReason == ToolUse) $ do
        hPutStrLn stderr $
          "[baikai-smoke] tool round-trip "
            <> caseLabel
            <> " exhausted before final text; response="
            <> show finalResp
        exitFailure
      let toolResults =
            [ payload
            | ToolResultMessage payload <- Vector.toList (ctx1 ^. #messages),
              payload ^. #toolName == "get_time"
            ]
          finalText = flattenAssistantText (flattenAssistantBlocks finalResp)
          mentions =
            Text.isInfixOf "2026" finalText
              || Text.isInfixOf "15:09" finalText
              || Text.isInfixOf "May 14" finalText
      when (null toolResults) $ do
        hPutStrLn stderr $
          "[baikai-smoke] tool round-trip "
            <> caseLabel
            <> ": no get_time ToolResultMessage was appended. Context: "
            <> show ctx1
        exitFailure
      when (not mentions) $ do
        hPutStrLn stderr $
          "[baikai-smoke] tool round-trip "
            <> caseLabel
            <> ": final answer did not mention the timestamp. Text: "
            <> Text.unpack finalText
        exitFailure
      hPutStrLn stderr $
        "[baikai-smoke] tool round-trip "
          <> caseLabel
          <> " ok via "
          <> envVar
          <> "; final mentions timestamp"
      pure True

firstSetEnv :: [String] -> IO (Maybe (String, String))
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure $ case find (\(_, m) -> isJust m) results of
    Just (v, Just val) -> Just (v, val)
    _ -> Nothing
