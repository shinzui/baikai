module SmokeOptions (SmokeOptions (..), parseSmokeOptions, missingKeys, keyPresent, caseNames, caseProvider, selectCaseNames, cacheCaseNames, isCacheCase) where

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

caseNames :: [String]
caseNames = ["astra-text", "astra-tools", "fable-text", "fable-tools", "sol-text", "sol-tools", "luna-text", "luna-tools", "opus55-text", "opus55-tools", "sol61-text", "sol61-tools", "sonnet55-text", "sonnet55-tools", "haiku55-text", "haiku55-tools"]

selectCaseNames :: Maybe String -> [String]
selectCaseNames selected = filter (\name -> maybe True (== name) selected) caseNames

caseProvider :: String -> Maybe String
caseProvider name
  | isCacheCase name = Just "openai"
  | name `elem` ["astra-text", "astra-tools", "sol-text", "sol-tools", "luna-text", "luna-tools", "sol61-text", "sol61-tools"] = Just "openai"
  | name `elem` ["fable-text", "fable-tools", "opus55-text", "opus55-tools", "sonnet55-text", "sonnet55-tools", "haiku55-text", "haiku55-tools"] = Just "anthropic"
  | otherwise = Nothing

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
