-- | Structured-output smoke: send a request carrying a JSON schema
-- and assert the returned assistant text is a JSON object that
-- validates against that schema (an object with a string @name@ and
-- an integer @age@).
--
-- Mirrors the exit-code/skip style of 'ToolsSmoke.runToolCase':
-- skips (returns 'False') when the relevant API key is absent; calls
-- 'System.Exit.exitFailure' on assertion failure so the wrapping
-- @main@ surfaces it as a test-suite failure.
--
-- baikai does not ship a JSON Schema validator (and pulling one in is
-- out of scope), so the conformance check is the exact shape the
-- schema describes: a JSON object with @name :: string@ and
-- @age :: number@. That the model returns precisely this shape — even
-- though the prompt never spells out a JSON format — is the proof the
-- provider is enforcing the attached schema server-side.
module StructuredSmoke
  ( ApiCase (..),
    runStructuredCase,
  )
where

import Baikai
import Control.Lens ((&), (.~))
import Control.Monad (when)
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | The shape mirrors 'Main.ApiCase' from @Smoke.hs@; re-declared
-- locally so 'StructuredSmoke' has no dependency on the smoke
-- entry-point module's internals.
data ApiCase = ApiCase
  { caseLabel :: !String,
    caseEnvVars :: ![String],
    caseModel :: !Model
  }

-- | The JSON Schema attached to the request: an object with a
-- required string @name@ and a required integer @age@.
personSchema :: Value
personSchema =
  Aeson.object
    [ "type" .= ("object" :: Text),
      "properties"
        .= Aeson.object
          [ "name" .= Aeson.object ["type" .= ("string" :: Text)],
            "age" .= Aeson.object ["type" .= ("integer" :: Text)]
          ],
      "required" .= (["name", "age"] :: [Text]),
      "additionalProperties" .= False
    ]

runStructuredCase :: ApiCase -> IO Bool
runStructuredCase ApiCase {caseLabel, caseEnvVars, caseModel} = do
  matched <- firstSetEnv caseEnvVars
  case matched of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] none of "
          <> show caseEnvVars
          <> " set; skipping structured-output "
          <> caseLabel
          <> "."
      pure False
    Just (envVar, key) -> do
      let ctx =
            emptyContext
              & #systemPrompt .~ Just "Extract the person's name and age."
              & #messages
                .~ Vector.singleton
                  (user "Ada Lovelace, the mathematician, was 36.")
          opts =
            emptyOptions
              & #maxTokens .~ Just 256
              & #temperature .~ Just 0.0
              & #responseFormat
                .~ Just (JsonSchema {name = "person", schema = personSchema, strict = True})
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
      resp <- completeRequest caseModel ctx opts
      let flat = flattenAssistantText (flattenAssistantBlocks resp)
      case Aeson.eitherDecodeStrict (Text.encodeUtf8 flat) of
        Left err -> do
          hPutStrLn stderr $
            "[baikai-smoke] structured "
              <> caseLabel
              <> " via "
              <> envVar
              <> ": response was not valid JSON ("
              <> err
              <> "); raw text: "
              <> Text.unpack flat
          exitFailure
        Right val -> do
          when (not (validatesAgainstSchema val)) $ do
            hPutStrLn stderr $
              "[baikai-smoke] structured "
                <> caseLabel
                <> " via "
                <> envVar
                <> ": JSON did not match the schema (need object with string name + number age); got: "
                <> Text.unpack flat
            exitFailure
          hPutStrLn stderr $
            "[baikai-smoke] structured "
              <> caseLabel
              <> " ok via "
              <> envVar
              <> "; json="
              <> Text.unpack flat
          pure True

-- | The exact shape @personSchema@ describes: a JSON object carrying
-- a string @name@ and a numeric @age@.
validatesAgainstSchema :: Value -> Bool
validatesAgainstSchema = \case
  Object o ->
    case (KeyMap.lookup "name" o, KeyMap.lookup "age" o) of
      (Just (String _), Just (Number _)) -> True
      _ -> False
  _ -> False

firstSetEnv :: [String] -> IO (Maybe (String, String))
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure $ case find (\(_, m) -> isJust m) results of
    Just (v, Just val) -> Just (v, val)
    _ -> Nothing
