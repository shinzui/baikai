module Main (main) where

import Baikai
import Baikai.Models.Generated (typesafe_jev_latest)
import Baikai.Provider.TypeSafe.Api (typesafeProvider)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as A
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  if "--live" `notElem` args
    then putStrLn "TypeSafe live verification skipped (select --live explicitly)."
    else do
      key <- lookupEnv "TYPESAFE_API_KEY"
      case key of
        Nothing -> die "TypeSafe live verification did not run: TYPESAFE_API_KEY is absent."
        Just k | T.null (T.strip (T.pack k)) -> die "TypeSafe live verification did not run: TYPESAFE_API_KEY is empty."
        _ -> pure ()
      reg <- newProviderRegistry
      registerApiProviderWith reg typesafeProvider
      let schemaValue = A.object ["type" A..= ("object" :: Text), "properties" A..= A.object ["urgent" A..= A.object ["type" A..= ("boolean" :: Text), "description" A..= ("Is service blocked?" :: Text)]], "additionalProperties" A..= False]
          ctx = contextOf [userData (A.object ["ticket" A..= ("Checkout is unavailable." :: Text)])]
          opts = emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "ticket" schemaValue))
      r <- completeRequestWith reg typesafe_jev_latest ctx opts
      case responseError r of Just e -> die (show e); Nothing -> pure ()
      case V.toList (flattenAssistantData (r ^. #message . #content)) of
        [d]
          | Just ps <- d ^. #probabilities,
            Just urgent <- Map.lookup "urgent" ps,
            Map.keys urgent == ["false", "true"],
            all (\p -> not (isNaN p || isInfinite p) && p >= 0 && p <= 1) urgent ->
              putStrLn "TypeSafe live verification passed (one call)."
        _ -> die "TypeSafe live verification returned an invalid data shape."
