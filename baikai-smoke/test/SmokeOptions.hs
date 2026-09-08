module SmokeOptions (SmokeOptions (..), parseSmokeOptions, missingKeys, keyPresent) where

data SmokeOptions = SmokeOptions
  { newModels :: Bool,
    requireKeys :: Bool
  }
  deriving stock (Eq, Show)

parseSmokeOptions :: [String] -> Either String SmokeOptions
parseSmokeOptions = go (SmokeOptions False False)
  where
    go opts [] = Right opts
    go opts ("--new-models" : rest) = go opts {newModels = True} rest
    go opts ("--require-keys" : rest) = go opts {requireKeys = True} rest
    go _ (arg : _) = Left ("unknown smoke option: " <> arg)

-- Empty values cannot authenticate. Keep this pure so missing-key tests never
-- consult the process environment or expose credential values.
keyPresent :: Maybe String -> Bool
keyPresent = maybe False (not . null)

missingKeys :: [(String, Maybe String)] -> [[String]] -> [[String]]
missingKeys env = filter (not . any (keyPresent . (>>= id) . (`lookup` env)))
