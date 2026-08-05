module Main (main) where

import Baikai.Agent.Run (runnerPlaceholder)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Agent.Run"
      [ placeholderTest
      ]

placeholderTest :: TestTree
placeholderTest =
  testCase "the package skeleton builds and its suite runs" $
    runnerPlaceholder @?= ()
