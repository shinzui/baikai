-- | CAP-29, docs/capabilities/neutral-judgments.md.
module Shape.Cap29 (shape) where

import Baikai.Judgment (compileJudgments, judgmentList)
import Baikai.ResponseFormat (jsonSchemaFormat)
import Shape.Fixtures (personSchema)

shape :: IO ()
shape = do
  -- BEGIN CAP-29
  case compileJudgments (jsonSchemaFormat "ticket" personSchema) of
    Left problem -> print problem
    Right questions -> print (judgmentList questions)

-- END CAP-29
