module JudgmentSpec (tests) where

import Baikai hiding (confidence, format, kind, name, probabilities)
import Baikai.Judgment qualified as J
import Baikai.Models.Generated qualified as Models
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Text qualified
import Data.Vector qualified as V
import FetchModelsCore qualified as F
import GenModelsCore qualified as G
import Test.Tasty
import Test.Tasty.HUnit

schemaFixture :: A.Value
schemaFixture =
  A.object
    [ "type" A..= ("object" :: Text),
      "additionalProperties" A..= False,
      "required" A..= (["urgent", "category", "severity"] :: [Text]),
      "properties"
        A..= A.object
          [ "urgent" A..= A.object ["type" A..= ("boolean" :: Text), "description" A..= ("Is service blocked?" :: Text)],
            "category" A..= branches [A.String "billing", A.String "technical"] [A.String "Payment issue", A.String "Product malfunction"] "Classify the issue.",
            "severity" A..= branches (map A.toJSON [0 :: Int, 1, 2]) (map A.String ["Minor", "Disruptive", "Blocking"]) "Rate impact."
          ]
    ]

branches :: [A.Value] -> [A.Value] -> Text -> A.Value
branches vs ds instr = A.object ["description" A..= instr, "anyOf" A..= [A.object ["const" A..= v, "description" A..= d] | (v, d) <- zip vs ds]]

format :: A.Value -> JsonSchemaFormat
format = jsonSchemaFormat "judgments"

opts :: Options
opts = emptyOptions & #responseFormat .~ Just (JsonSchema (format schemaFixture))

ctx :: Context
ctx = contextOf [userData (A.object ["ticket" A..= ("Checkout is unavailable." :: Text)])]

answers :: M.Map Text JudgmentAnswer
answers =
  M.fromList
    [ ("urgent", PredicateAnswer 0.83),
      ("category", ChoiceAnswer "technical" (M.fromList [("billing", 0.2), ("technical", 0.7)]) (Just 0.65)),
      ("severity", ScoreAnswer (Just 1.5) (M.fromList [("0", 0.1), ("1", 0.3), ("2", 0.6)]) (Just 0.55))
    ]

withProperty :: A.Value -> A.Value
withProperty v = A.object ["type" A..= ("object" :: Text), "properties" A..= A.object ["x" A..= v]]

enum :: [A.Value] -> A.Value
enum vs = A.object ["enum" A..= vs]

compiled :: IO Judgments
compiled = either (assertFailure . show) pure (compileJudgments (format schemaFixture))

assertPath :: Text -> Either BaikaiError a -> IO ()
assertPath p r = case r of
  Left e -> e ^. #requestProblem @?= Just (UnsupportedFeature p)
  Right _ -> assertFailure "expected refusal"

tests :: TestTree
tests =
  testGroup
    "neutral judgments"
    [ testCase "fetch render preserves curated judgment output and data modality" $ do
        let m = F.CatalogModel "jev-latest" "Jev" False [InputText, InputData] JudgmentOutput (F.CatalogCost 0 0 0 0) Nothing Nothing 0 0 Nothing Nothing
            c = F.Catalog "typesafe" "https://api.typesafe.ai" "typesafe-system-one" [m]
        case A.eitherDecode (BL.fromStrict (F.renderCatalog c)) :: Either String G.CatalogFile of
          Left e -> assertFailure e
          Right catalog -> case G.flattenEntries catalog of
            [(_, g)] -> do G.outputKind g @?= JudgmentOutput; G.input g @?= [InputText, InputData]
            _ -> assertFailure "one model required",
      testCase "catalog facts and generative legacy default" $ do
        forM_ [Models.typesafe_jev_latest, Models.typesafe_jev_preview] $ \m -> do
          isJudgmentOnly m @?= True
          m ^. #api @?= TypeSafeSystemOne
          m ^. #input @?= [InputText, InputData]
          A.eitherDecode (A.encode m) @?= Right m
        forM_ Models.allModels $ \m -> isJudgmentOnly m @?= (m ^. #provider == "typesafe")
        let old = case A.toJSON emptyModel of A.Object o -> A.Object (KM.delete "outputKind" o); v -> v
        fmap (^. #outputKind) ((A.fromJSON old :: A.Result Model)) @?= A.Success GenerativeOutput,
      testCase "ordered fixture with exact instructions and criteria; deterministic fallback" $ do
        js <- compiled
        V.toList (judgmentList js)
          @?= [ Judgment "urgent" (A.String "Is service blocked?") (PredicateJudgment Nothing),
                Judgment "category" (A.String "Classify the issue.") (ChoiceJudgment (V.fromList [("billing", Just (A.String "Payment issue")), ("technical", Just (A.String "Product malfunction"))])),
                Judgment "severity" (A.String "Rate impact.") (ScoreJudgment (V.fromList (map (Just . A.String) ["Minor", "Disruptive", "Blocking"])))
              ]
        let noRequired = case schemaFixture of A.Object o -> A.Object (KM.delete "required" o); v -> v
        fallback <- either (assertFailure . show) pure (compileJudgments (format noRequired))
        map (^. #name) (V.toList (judgmentList fallback)) @?= ["category", "severity", "urgent"],
      testCase "predicate criteria and neutral non-string content are preserved" $ do
        forM_ [A.String "", A.Bool False, A.Number 0, A.object [], A.toJSON ([] :: [Int])] $ \d -> do
          let p = A.object ["description" A..= d, "oneOf" A..= [A.object ["const" A..= False, "description" A..= ("no" :: Text)], A.object ["const" A..= True, "description" A..= ("yes" :: Text)]]]
          js <- either (assertFailure . show) pure (compileJudgments (format (withProperty p)))
          lookupJudgment "x" js @?= Just (Judgment "x" d (PredicateJudgment (Just (A.String "yes", A.String "no")))),
      testCase "all unsupported schema shapes and boundary sizes" $ do
        forM_ [A.object [], A.object ["type" A..= ("string" :: Text)], A.object ["type" A..= ("object" :: Text)], enum [], enum [A.String "x", A.String "x"], enum [A.Bool True, A.String "x"], enum (map A.toJSON [0 :: Int, 2]), enum (map A.toJSON [1 :: Int, 2, 3]), enum [A.Number 0], enum (map A.toJSON [0 :: Int .. 10]), enum [A.Number 0, A.Number 1.5], A.object ["allOf" A..= ([] :: [Int])], A.object ["anyOf" A..= [A.object []]], A.object ["type" A..= ("boolean" :: Text), "enum" A..= [A.String "x"]]] $ \p ->
          assertBool (show p) (isLeft (compileJudgments (format (withProperty p))))
        forM_ [1, 255] $ \n -> assertBool "choice boundary accepted" (not (isLeft (compileJudgments (format (withProperty (enum [A.String (fromString (show i)) | i <- [1 .. n :: Int]]))))))
        forM_ [2, 10] $ \n -> assertBool "score boundary accepted" (not (isLeft (compileJudgments (format (withProperty (enum (map A.toJSON [0 .. n - 1 :: Int])))))))
        assertPath "Options.responseFormat.schema.properties.x" (compileJudgments (format (withProperty (enum [A.String (fromString (show i)) | i <- [1 .. 256 :: Int]]))))
        forM_ [("required", A.toJSON (["missing"] :: [Text])), ("additionalProperties", A.Bool True), ("$ref", A.String "#defs/x")] $ \(k, v) -> do
          let s = case schemaFixture of A.Object o -> A.Object (KM.insert k v o); x -> x
          assertPath ("Options.responseFormat.schema." <> fromString (showKey k)) (compileJudgments (format s)),
      testCase "every explicit generation control is refused by path" $ do
        let controls = [("maxTokens", opts & #maxTokens .~ Just 1), ("temperature", opts & #temperature .~ Just 0), ("topP", opts & #topP .~ Just 1), ("stopSequences", opts & #stopSequences .~ ["x"]), ("seed", opts & #seed .~ Just 1), ("frequencyPenalty", opts & #frequencyPenalty .~ Just 0), ("presencePenalty", opts & #presencePenalty .~ Just 0), ("thinking", opts & #thinking .~ Just ThinkingLow), ("cacheRetention", opts & #cacheRetention .~ Just CacheRetentionShort), ("speed", opts & #speed .~ Just SpeedStandard)]
        forM_ controls $ \(field, o) -> assertPath ("Options." <> field) (prepareJudgment ctx o)
        forM_ [ToolChoiceAuto, ToolChoiceNone, ToolChoiceRequired, ToolChoiceSpecific "x"] $ \choice -> assertPath "Options.toolChoice" (prepareJudgment ctx (opts & #toolChoice .~ Just choice))
        assertBool "explicit no caching accepted" (not (isLeft (prepareJudgment ctx (opts & #cacheRetention .~ Just CacheRetentionNone)))),
      testCase "context checks precede option and schema checks" $ do
        assertPath "Context.systemPrompt" (prepareJudgment (ctx & #systemPrompt .~ Just "") emptyOptions)
        forM_ [contextOf [], contextOf [user "x", user "y"]] $ \c -> assertPath "Context.messages" (prepareJudgment c opts)
        assertPath "Context.messages[0]" (prepareJudgment (contextOf [assistant "x"]) opts)
        assertPath "Context.messages[0]" (prepareJudgment (contextOf [toolResult "call" "tool" "result" False]) opts)
        assertPath "Context.tools" (prepareJudgment (ctx & #tools .~ V.singleton emptyTool) opts)
        forM_ [emptyOptions, emptyOptions & #responseFormat .~ Just JsonObject] $ \o -> assertPath "Options.responseFormat" (prepareJudgment ctx o),
      testCase "complete data preserves provider selection, expected score and non-normalized probabilities" $ do
        js <- compiled
        d <- either (assertFailure . show) pure (validateAnswers js answers)
        d ^. #value @?= A.object ["urgent" A..= True, "category" A..= ("technical" :: Text), "severity" A..= (1.5 :: Double)]
        d ^. #confidence @?= Just (M.fromList [("category", 0.65), ("severity", 0.55)])
        A.eitherDecode (A.encode d) @?= Right d
        let other = M.insert "category" (ChoiceAnswer "billing" (M.fromList [("billing", 0.2), ("technical", 0.7)]) Nothing) answers
        selected <- either (assertFailure . show) pure (validateAnswers js other)
        case selected ^. #value of A.Object o -> KM.lookup "category" o @?= Just (A.String "billing"); _ -> assertFailure "object required"
        tied <- either (assertFailure . show) pure (validateAnswers js (M.insert "severity" (ScoreAnswer Nothing (M.fromList [("0", 0.5), ("1", 0.5), ("2", 0)]) Nothing) answers))
        case tied ^. #value of A.Object o -> KM.lookup "severity" o @?= Just (A.Number 0); _ -> assertFailure "object required",
      testCase "malformed answer names, kinds, distributions, selected labels and numeric evidence" $ do
        js <- compiled
        forM_ [M.delete "urgent" answers, M.insert "extra" (PredicateAnswer 0.5) answers, M.insert "category" (PredicateAnswer 0.5) answers, M.insert "category" (ChoiceAnswer "other" (M.fromList [("billing", 0.2), ("technical", 0.7)]) Nothing) answers, M.insert "category" (ChoiceAnswer "billing" M.empty Nothing) answers] $ \as ->
          case validateAnswers js as of Left e -> e ^. #category @?= DecodeFailure; Right _ -> assertFailure "expected failure"
        forM_ [-0.1, 1.1, 1 / 0, 0 / 0] $ \bad -> forM_ [M.insert "urgent" (PredicateAnswer bad) answers, M.insert "category" (ChoiceAnswer "billing" (M.fromList [("billing", 0.2), ("technical", 0.7)]) (Just bad)) answers] $ \as ->
          case validateAnswers js as of Left e -> e ^. #category @?= DecodeFailure; Right _ -> assertFailure "expected numeric failure"
        case validateAnswers js (M.insert "urgent" (RefusedAnswer (Just "policy")) answers) of
          Left e -> do e ^. #category @?= ContentFiltered; e ^. #refusalCategory @?= Just "policy"
          Right _ -> assertFailure "refusal required"
    ]
  where
    fromString = Data.Text.pack
    showKey = Data.Aeson.Key.toString
