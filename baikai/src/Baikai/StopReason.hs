{-# LANGUAGE LambdaCase #-}

-- | Why the model stopped generating.
--
-- A small closed sum populated on every 'Baikai.Message.AssistantMessage'.
-- API providers map their per-vendor stop reason onto this enum; CLI
-- providers populate @Stop@ on success and @ErrorReason@ when the
-- subprocess reports an error.
--
-- Constructor encoding on the wire is snake-case: @"stop"@, @"length"@,
-- @"tool_use"@, @"error"@. @ErrorReason@ is renamed to
-- @"error"@ so the Haskell name does not clash with @Prelude.Either.Left@
-- callers and the wire shape stays terse.
module Baikai.StopReason (StopReason (..)) where

import Data.Aeson
  ( FromJSON (parseJSON),
    Options (..),
    ToJSON (toJSON),
    defaultOptions,
    genericParseJSON,
    genericToJSON,
  )
import Data.Char (toLower)
import GHC.Generics (Generic)

data StopReason
  = Stop
  | Length
  | ToolUse
  | ErrorReason
  deriving stock (Eq, Show, Generic)

stopReasonOptions :: Options
stopReasonOptions =
  defaultOptions
    { constructorTagModifier = \case
        "ErrorReason" -> "error"
        s -> camelToSnake s
    }
  where
    camelToSnake :: String -> String
    camelToSnake [] = []
    camelToSnake (c : cs) = toLower c : go cs
      where
        go [] = []
        go (x : xs)
          | x `elem` ['A' .. 'Z'] = '_' : toLower x : go xs
          | otherwise = x : go xs

instance FromJSON StopReason where parseJSON = genericParseJSON stopReasonOptions

instance ToJSON StopReason where toJSON = genericToJSON stopReasonOptions
