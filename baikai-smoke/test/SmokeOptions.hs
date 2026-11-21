module SmokeOptions (SmokeOptions (..), parseSmokeOptions, missingKeys, keyPresent, caseNames, caseProvider, selectCaseNames, selectModelCases, keysFor, cacheCaseNames, isCacheCase) where

import Baikai.Model (Model, provider)
import Baikai.Models.Generated qualified as Models
import Data.Text qualified as Text

data SmokeOptions = SmokeOptions
  { newModels :: Bool,
    requireKeys :: Bool,
    selectedCase :: Maybe String
  }
  deriving stock (Eq, Show)

parseSmokeOptions :: [String] -> Either String SmokeOptions
parseSmokeOptions = go (SmokeOptions False False Nothing)
  where
    go opts []
      | maybe False isCacheCase (selectedCase opts) && newModels opts = Left "cache cases cannot combine with --new-models"
      | selectedCase opts /= Nothing && not (maybe False isCacheCase (selectedCase opts)) && not (newModels opts) = Left "--case requires --new-models"
      | otherwise = Right opts
    go opts ("--new-models" : rest) = go opts {newModels = True} rest
    go opts ("--require-keys" : rest) = go opts {requireKeys = True} rest
    go opts ("--case" : name : rest)
      | selectedCase opts /= Nothing = Left "select exactly one --case"
      | name `elem` (caseNames <> cacheCaseNames) = go opts {selectedCase = Just name} rest
      | otherwise = Left ("unknown case; choose one of " <> show caseNames)
    go _ (arg : _) = Left ("unknown smoke option: " <> arg)

-- Keep each selector beside the model record used by the live runner.
modelCases :: [(String, Model, Bool)]
modelCases =
  [ (stem <> suffix, model, tools)
  | (stem, model) <-
      [ ("astra", Models.openai_gpt_6_astra),
        ("fable", Models.anthropic_claude_fable_5_1),
        ("sol", Models.openai_gpt_6_sol),
        ("luna", Models.openai_gpt_6_luna),
        ("opus55", Models.anthropic_claude_opus_5_5),
        ("sol61", Models.openai_gpt_6_1_sol),
        ("sonnet55", Models.anthropic_claude_sonnet_5_5),
        ("haiku55", Models.anthropic_claude_haiku_5_5),
        ("terra61", Models.openai_gpt_6_1_terra),
        ("astra62", Models.openai_gpt_6_2_astra),
        ("sol62", Models.openai_gpt_6_2_sol)
      ],
    (suffix, tools) <- [("-text", False), ("-tools", True)]
  ]

caseNames :: [String]
caseNames = [name | (name, _, _) <- modelCases]

selectCaseNames :: Maybe String -> [String]
selectCaseNames selected = filter (matches selected) caseNames

selectModelCases :: Maybe String -> [(String, Model, [String], Bool)]
selectModelCases selected =
  [ (name, model, keysFor (Text.unpack (provider model)), tools)
  | (name, model, tools) <- modelCases,
    matches selected name
  ]

matches :: Maybe String -> String -> Bool
matches selected name = maybe True (== name) selected

caseProvider :: String -> Maybe String
caseProvider name
  | isCacheCase name = Just "openai"
  | otherwise = lookup name [(key, Text.unpack (provider model)) | (key, model, _) <- modelCases]

keysFor :: String -> [String]
keysFor "openai" = ["OPENAI_KEY", "OPENAI_API_KEY"]
keysFor "anthropic" = ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]
keysFor _ = []

-- Empty values cannot authenticate. Keep this pure so missing-key tests never
-- consult the process environment or expose credential values.
keyPresent :: Maybe String -> Bool
keyPresent = maybe False (not . null)

missingKeys :: [(String, Maybe String)] -> [[String]] -> [[String]]
missingKeys env = filter (not . any (keyPresent . (>>= id) . (`lookup` env)))

-- Kept separate so --new-models continues to select only its original cases.
cacheCaseNames :: [String]
cacheCaseNames = ["openai-cache-responses", "openai-cache-chat"]

isCacheCase :: String -> Bool
isCacheCase = (`elem` cacheCaseNames)
