{-# LANGUAGE LambdaCase #-}

-- | Provider-neutral closed-set questions and strict answer validation.
module Baikai.Judgment
  ( JudgmentKind (..),
    Judgment (..),
    Judgments,
    judgmentList,
    lookupJudgment,
    compileJudgments,
    judgmentUserMessage,
    refuseGenerationControls,
    prepareJudgment,
    JudgmentAnswer (..),
    validateAnswers,
    judgmentMethod,
  )
where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Content (DataContent (..))
import Baikai.Context (Context)
import Baikai.Error
import Baikai.Message (Message (..))
import Baikai.Options (Options)
import Baikai.ResponseFormat (JsonSchemaFormat, ResponseFormat (..))
import Control.Lens ((^.))
import Control.Monad (forM, unless, when)
import Data.Aeson (Object, Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Scientific qualified as Sci
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)

data JudgmentKind
  = PredicateJudgment (Maybe (Value, Value))
  | ChoiceJudgment (Vector (Text, Maybe Value))
  | ScoreJudgment (Vector (Maybe Value))
  deriving stock (Eq, Show, Generic)

data Judgment = Judgment {name :: !Text, instructions :: !Value, kind :: !JudgmentKind}
  deriving stock (Eq, Show, Generic)

data Judgments = Judgments !(Vector Judgment) !(Map Text Judgment)
  deriving stock (Eq, Show)

judgmentList :: Judgments -> Vector Judgment
judgmentList (Judgments js _) = js

lookupJudgment :: Text -> Judgments -> Maybe Judgment
lookupJudgment n (Judgments _ ix) = Map.lookup n ix

schemaPath :: Text
schemaPath = "Options.responseFormat.schema"

refuse :: Text -> Text -> Either BaikaiError a
refuse p why = Left (unsupportedFeature p (p <> ": " <> why))

asObject :: Text -> Value -> Either BaikaiError Object
asObject _ (Object o) = Right o
asObject p _ = refuse p "expected an object"

allowed :: Text -> [Text] -> Object -> Either BaikaiError ()
allowed p keys o = case sort [K.toText k | k <- KM.keys o, K.toText k `notElem` keys] of
  [] -> Right ()
  k : _ -> refuse (p <> "." <> k) "unsupported schema keyword"

description :: Object -> Maybe Value
description o = case KM.lookup "description" o of Just Null -> Nothing; x -> x

compileJudgments :: JsonSchemaFormat -> Either BaikaiError Judgments
compileJudgments format = do
  o <- asObject schemaPath (format ^. #schema)
  allowed schemaPath ["type", "properties", "required", "additionalProperties", "title", "description"] o
  unless (KM.lookup "type" o == Just (String "object")) (refuse (schemaPath <> ".type") "expected object type")
  props <- maybe (refuse (schemaPath <> ".properties") "properties required") (asObject (schemaPath <> ".properties")) (KM.lookup "properties" o)
  when (KM.null props) (refuse (schemaPath <> ".properties") "questions must not be empty")
  case KM.lookup "additionalProperties" o of
    Nothing -> pure ()
    Just (Bool False) -> pure ()
    _ -> refuse (schemaPath <> ".additionalProperties") "only false is supported"
  let names = sort (map K.toText (KM.keys props))
  required <- case KM.lookup "required" o of
    Nothing -> pure []
    Just (Array xs) -> forM (V.toList xs) $ \case
      String t | t `elem` names -> pure t
      _ -> refuse (schemaPath <> ".required") "required must name declared properties"
    _ -> refuse (schemaPath <> ".required") "expected an array"
  let order = if sort required == names then required else names
  js <- forM order $ \n -> do
    let p = schemaPath <> ".properties." <> n
    prop <- maybe (refuse p "property missing") (asObject p) (KM.lookup (K.fromText n) props)
    k <- compileKind p prop
    pure (Judgment n (maybe (String n) id (description prop)) k)
  pure (Judgments (V.fromList js) (Map.fromList [(name j, j) | j <- js]))

compileKind :: Text -> Object -> Either BaikaiError JudgmentKind
compileKind p o = do
  allowed p ["type", "enum", "anyOf", "oneOf", "title", "description"] o
  let alternatives = [v | key <- ["enum", "anyOf", "oneOf"], Just v <- [KM.lookup key o]]
  case alternatives of
    [] | KM.lookup "type" o == Just (String "boolean") -> pure (PredicateJudgment Nothing)
    [v] -> do
      let enum = KM.member "enum" o
      xs <- case v of Array a | not (V.null a) -> pure (V.toList a); _ -> refuse p "expected nonempty alternatives"
      entries <-
        if enum
          then pure [(x, Nothing) | x <- xs]
          else forM xs $ \branch -> do
            b <- asObject p branch
            allowed p ["const", "description", "title"] b
            val <- maybe (refuse p "const required on every branch") pure (KM.lookup "const" b)
            pure (val, description b)
      let values = map fst entries
          ty = KM.lookup "type" o
          typeAllowed allowedTypes = unless (maybe True (`elem` map String allowedTypes) ty) (refuse p "conflicting property type")
      when (length values /= Set.size (Set.fromList values)) (refuse p "duplicate alternatives")
      case values of
        Bool _ : _ -> do
          typeAllowed ["boolean"]
          unless (sort values == [Bool False, Bool True]) (refuse p "predicate must declare true and false")
          let get b = maybe Null id (lookup (Bool b) entries >>= id)
              criteria = if any (isJust . snd) entries then Just (get True, get False) else Nothing
          pure (PredicateJudgment criteria)
        String _ : _ -> do
          typeAllowed ["string"]
          labels <- forM entries $ \case (String t, d) -> pure (t, d); _ -> refuse p "mixed alternatives"
          when (length labels > 255) (refuse p "at most 255 labels")
          pure (ChoiceJudgment (V.fromList labels))
        Number _ : _ -> do
          typeAllowed ["integer"]
          levels <- forM entries $ \case
            (Number n, d) | Just i <- (Sci.toBoundedInteger n :: Maybe Int) -> pure (i, d)
            _ -> refuse p "levels must be integral numbers"
          let ordered = sortOn fst levels; count = length ordered
          unless (count >= 2 && count <= 10 && map fst ordered == [0 .. count - 1]) (refuse p "score levels must be 0 to N-1 with 2 to 10 levels")
          pure (ScoreJudgment (V.fromList (map snd ordered)))
        _ -> refuse p "unsupported alternatives"
    _ -> refuse p "unsupported or conflicting validation keywords"

judgmentUserMessage :: Context -> Either BaikaiError Message
judgmentUserMessage ctx = do
  when (isJust (ctx ^. #systemPrompt)) (refuse "Context.systemPrompt" "judgments do not accept a system prompt")
  unless (V.length (ctx ^. #messages) == 1) (refuse "Context.messages" "exactly one user message required")
  msg <- case V.head (ctx ^. #messages) of
    m@UserMessage {} -> Right m
    _ -> refuse "Context.messages[0]" "expected a user message"
  unless (V.null (ctx ^. #tools)) (refuse "Context.tools" "judgments do not accept tools")
  pure msg

refuseGenerationControls :: Options -> Either BaikaiError ()
refuseGenerationControls o =
  mapM_
    check
    [ ("maxTokens", isJust (o ^. #maxTokens)),
      ("temperature", isJust (o ^. #temperature)),
      ("topP", isJust (o ^. #topP)),
      ("stopSequences", not (null (o ^. #stopSequences))),
      ("seed", isJust (o ^. #seed)),
      ("frequencyPenalty", isJust (o ^. #frequencyPenalty)),
      ("presencePenalty", isJust (o ^. #presencePenalty)),
      ("thinking", isJust (o ^. #thinking)),
      ("toolChoice", isJust (o ^. #toolChoice)),
      ("cacheRetention", maybe False (/= CacheRetentionNone) (o ^. #cacheRetention)),
      ("speed", isJust (o ^. #speed))
    ]
  where
    check (n, True) = refuse ("Options." <> n) "generation control is unsupported for judgments"
    check (_, False) = pure ()

prepareJudgment :: Context -> Options -> Either BaikaiError (Message, Judgments)
prepareJudgment ctx opts = do
  msg <- judgmentUserMessage ctx
  refuseGenerationControls opts
  fmt <- case opts ^. #responseFormat of
    Just (JsonSchema f) -> pure f
    _ -> refuse "Options.responseFormat" "closed-set JsonSchema required"
  js <- compileJudgments fmt
  pure (msg, js)

data JudgmentAnswer
  = PredicateAnswer Double
  | ChoiceAnswer {selected :: Text, probabilities :: Map Text Double, confidence :: Maybe Double}
  | ScoreAnswer {expected :: Maybe Double, probabilities :: Map Text Double, confidence :: Maybe Double}
  | RefusedAnswer (Maybe Text)
  deriving stock (Eq, Show, Generic)

judgmentMethod :: Text
judgmentMethod = "provider_classification"

validateAnswers :: Judgments -> Map Text JudgmentAnswer -> Either BaikaiError DataContent
validateAnswers js answers = do
  let names = Set.fromList [name j | j <- V.toList (judgmentList js)]
      actual = Map.keysSet answers
  unless (actual == names) (Left (decodeError ("answer names differ: " <> T.intercalate "," (Set.toAscList ((names Set.\\ actual) <> (actual Set.\\ names))))))
  rows <- forM (V.toList (judgmentList js)) $ \j -> do
    a <- maybe (Left (decodeError (name j <> ": missing answer"))) Right (Map.lookup (name j) answers)
    let bad :: Text -> Either BaikaiError a
        bad why = Left (decodeError (name j <> ": " <> why))
        unit x = unless (not (isNaN x || isInfinite x) && x >= 0 && x <= 1) (bad "expected finite probability/confidence in [0,1]")
        distribution keys ps c = do
          unless (Map.keysSet ps == Set.fromList keys) (bad "distribution keys differ")
          mapM_ unit ps
          mapM_ unit c
    (v, ps, c) <- case (kind j, a) of
      (_, RefusedAnswer category) -> Left ((contentFiltered (name j <> ": provider refused answer")) {refusalCategory = category})
      (PredicateJudgment _, PredicateAnswer p) -> do
        unit p
        pure (Bool (p >= 0.5), Map.fromList [("true", p), ("false", 1 - p)], Nothing)
      (ChoiceJudgment choices, ChoiceAnswer chosen ps c) -> do
        let labels = map fst (V.toList choices)
        distribution labels ps c
        unless (chosen `elem` labels) (bad "selected undeclared label")
        pure (String chosen, ps, c)
      (ScoreJudgment levels, ScoreAnswer expScore ps c) -> do
        let indices = [0 .. V.length levels - 1]; keys = map (T.pack . show) indices
        distribution keys ps c
        mapM_ (\x -> unless (not (isNaN x || isInfinite x) && x >= 0 && x <= fromIntegral (V.length levels - 1)) (bad "expected score outside declared range")) expScore
        let best = foldl (\best i -> if Map.findWithDefault 0 (T.pack (show i)) ps > Map.findWithDefault 0 (T.pack (show best)) ps then i else best) 0 indices
            score = maybe (A.toJSON best) A.toJSON expScore
        pure (score, ps, c)
      _ -> bad "answer kind differs from question"
    pure (name j, v, ps, c)
  pure
    ( DataContent
        (Object (KM.fromList [(K.fromText n, v) | (n, v, _, _) <- rows]))
        (Just (Map.fromList [(n, ps) | (n, _, ps, _) <- rows]))
        (let cs = Map.fromList [(n, c) | (n, _, _, Just c) <- rows] in if Map.null cs then Nothing else Just cs)
        (Just judgmentMethod)
    )
