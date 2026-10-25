module Baikai.Provider.TypeSafe.Internal.Response (decodeResponse, responseObservations) where

import Baikai
import Baikai.Cost.Pricing (computeCost)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (unless)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import TypeSafe.Wire qualified as W

decodeResponse :: Model -> Judgments -> ByteString -> Either BaikaiError (DataContent, Text, Usage)
decodeResponse m js bytes = do
  r <- either (Left . decodeError) Right (W.decodeSystemOneResponse bytes)
  (model, u) <- responseFacts m r
  answers <- Map.fromList <$> traverse answer (Map.toList (r ^. #answers))
  dat <- validateAnswers js answers
  pure (dat, model, u)
  where
    answer (W.QuestionName n, a) = do
      let err :: Text -> Either BaikaiError a
          err why = Left (decodeError (n <> ": " <> why))
          number = either (Left . decodeError . ((n <> ": ") <>)) Right
          unit = number . W.unitInterval
      neutral <- case a of
        W.AnswerNoul noul -> PredicateAnswer <$> unit (noul ^. #noul)
        W.AnswerChoice choice -> ChoiceAnswer (choice ^. #choice) <$> traverse unit (choice ^. #probabilities) <*> (Just <$> unit (choice ^. #confidence))
        W.AnswerScore score -> do
          case lookupJudgment n js of
            Just j | ScoreJudgment levels <- j ^. #kind -> do
              let expectedLegend = Map.fromList [(T.pack (show i), maybe (A.String (T.pack (show i))) id desc) | (i, desc) <- zip [0 :: Int ..] (V.toList levels)]
              unless (fmap W.contentToValue (score ^. #legend) == expectedLegend) (err "legend differs from declared levels")
            _ -> err "score answer for undeclared or non-score question"
          ScoreAnswer <$> (Just <$> number (W.finiteDouble (score ^. #score))) <*> traverse unit (score ^. #probabilities) <*> (Just <$> unit (score ^. #confidence))
        W.AnswerBox _ -> err "box answers are unsupported"
        W.AnswerOther tag _ -> err ("unknown answer type " <> tag)
      pure (n, neutral)

responseFacts :: Model -> W.SystemOneResponse -> Either BaikaiError (Text, Usage)
responseFacts m r = do
  let W.ModelName model = r ^. #model
  unless (not (T.null (T.strip model))) (Left (decodeError "model must be nonempty"))
  u <- wireUsage m (r ^. #usage)
  pure (model, u)

wireUsage :: Model -> W.Usage -> Either BaikaiError Usage
wireUsage m w = do
  let i = w ^. #inputTokens; o = w ^. #outputTokens
  unless (i >= 0 && o >= 0) (Left (decodeError "usage token counts must be nonnegative"))
  let u =
        zeroUsage
          & #inputTokens .~ fromIntegral i
          & #outputTokens .~ fromIntegral o
          & #totalTokens .~ (fromIntegral i + fromIntegral o)
          & #availability .~ Just (UsageAvailability Set.empty False Set.empty)
  pure (u & #cost .~ computeCost m u)

-- | Keep independently valid observations even when an answer is malformed.
responseObservations :: Model -> ByteString -> (Observed Text, Observed Usage)
responseObservations m bytes = case A.decode bytes of
  Just (A.Object o) ->
    ( case KM.lookup "model" o of
        Just (A.String t) | not (T.null (T.strip t)) -> Observed t
        _ -> Unobserved,
      case KM.lookup "usage" o of
        Just v | A.Success w <- A.fromJSON v, Right u <- wireUsage m w -> Observed u
        _ -> Unobserved
    )
  _ -> (Unobserved, Unobserved)
