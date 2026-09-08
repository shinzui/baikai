module SmokeOptions (SmokeOptions (..), parseSmokeOptions, missingKeys, keyPresent, caseNames) where

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
      | selectedCase opts /= Nothing && not (newModels opts) = Left "--case requires --new-models"
      | otherwise = Right opts
    go opts ("--new-models" : rest) = go opts {newModels = True} rest
    go opts ("--require-keys" : rest) = go opts {requireKeys = True} rest
    go opts ("--case" : name : rest)
      | name `elem` caseNames = go opts {selectedCase = Just name} rest
      | otherwise = Left ("unknown case; choose one of " <> show caseNames)
    go _ (arg : _) = Left ("unknown smoke option: " <> arg)

caseNames :: [String]
caseNames = ["astra-text", "astra-tools", "fable-text", "fable-tools"]

-- Empty values cannot authenticate. Keep this pure so missing-key tests never
-- consult the process environment or expose credential values.
keyPresent :: Maybe String -> Bool
keyPresent = maybe False (not . null)

missingKeys :: [(String, Maybe String)] -> [[String]] -> [[String]]
missingKeys env = filter (not . any (keyPresent . (>>= id) . (`lookup` env)))
