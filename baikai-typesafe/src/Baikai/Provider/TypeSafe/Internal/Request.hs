{-# LANGUAGE LambdaCase #-}

module Baikai.Provider.TypeSafe.Internal.Request (prepareRequest, requestBytes) where

import Baikai
import Control.Lens ((^.))
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import TypeSafe.Wire qualified as W

requestBytes :: W.SystemOneRequest -> ByteString
requestBytes = W.encodeSystemOneRequest

prepareRequest :: Model -> Context -> Options -> Either BaikaiError (Judgments, W.SystemOneRequest)
prepareRequest m ctx opts = do
  (msg, js) <- prepareJudgment ctx opts
  state <- case msg of
    UserMessage p -> case V.toList (p ^. #content) of
      [UserText (TextContent t)] | InputText `elem` (m ^. #input) -> pure (W.ContentText t)
      [UserData v] | InputData `elem` (m ^. #input) -> requiredContent "Context.messages[0].content[0]" v
      [_] -> refused "Context.messages[0].content[0]" "unsupported input part or undeclared input modality"
      _ -> refused "Context.messages[0].content" "exactly one text or data part required"
    _ -> refused "Context.messages[0]" "expected user message"
  questions <- traverse question (judgmentList js)
  pure (js, W.SystemOneRequest (W.ModelName (m ^. #modelId)) state questions Map.empty)
  where
    question j = do
      let path = "Options.responseFormat.schema.properties." <> j ^. #name
      instr <- requiredContent (path <> ".description") (j ^. #instructions)
      q <- case j ^. #kind of
        PredicateJudgment cs -> do
          criteria <- traverse (\(yes, no) -> W.NoulCriteria <$> optionalContent (criterionPath path (Bool True) 0) yes <*> optionalContent (criterionPath path (Bool False) 1) no) cs
          pure (W.QuestionNoul (W.NoulQuestion (Just instr) criteria))
        ChoiceJudgment choices -> do
          cs <- V.imapM (\i (label, desc) -> (label,) <$> traverse (optionalContent (criterionPath path (String label) i)) desc >>= \(l, d) -> pure (l, d >>= id)) choices
          pure (W.QuestionChoice (W.ChoiceQuestion (Just instr) cs))
        ScoreJudgment levels -> do
          cs <- V.imapM (\i d -> requiredContent (criterionPath path (Number (fromIntegral i)) i) (maybe (String (T.pack (show i))) id d)) levels
          case NE.nonEmpty (V.toList cs) of
            Just nonempty -> pure (W.QuestionScore (W.ScoreQuestion (Just instr) nonempty))
            Nothing -> refused path "empty score levels"
      pure (W.QuestionName (j ^. #name), q)
    -- Retain the actual schema branch path when a dialect rejects a description.
    criterionPath path wanted fallback =
      let propertyName = T.drop (T.length "Options.responseFormat.schema.properties.") path
          property = do
            JsonSchema f <- opts ^. #responseFormat
            Object root <- Just (f ^. #schema)
            Object props <- KM.lookup "properties" root
            Object prop <- KM.lookup (Data.Aeson.Key.fromText propertyName) props
            pure prop
          branches = do
            prop <- property
            let keyword = if KM.member "oneOf" prop then "oneOf" else "anyOf"
            Array xs <- KM.lookup keyword prop
            let matches (Object b) = KM.lookup "const" b == Just wanted
                matches _ = False
            pure (Data.Aeson.Key.toText keyword, maybe fallback id (V.findIndex matches xs))
       in case branches of
            Just (keyword, i) -> path <> "." <> keyword <> "[" <> T.pack (show i) <> "].description"
            Nothing -> path <> ".description"

refused :: Text -> Text -> Either BaikaiError a
refused p why = Left (unsupportedFeature p (p <> ": " <> why))

requiredContent :: Text -> Value -> Either BaikaiError W.Content
requiredContent p v = maybe (refused p "TypeSafe content must be text, object or array") Right (W.contentFromValue v)

optionalContent :: Text -> Value -> Either BaikaiError (Maybe W.Content)
optionalContent _ Null = Right Nothing
optionalContent p v = Just <$> requiredContent p v
