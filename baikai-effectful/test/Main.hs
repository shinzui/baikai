-- | Test entry point for baikai-effectful. Drives the hermetic specs through one
-- tasty 'defaultMain'. The live spec (M4) is gated at runtime on an env var.
module Main (main) where

import CompleteSpec qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "baikai-effectful"
      [ CompleteSpec.tests
      ]
