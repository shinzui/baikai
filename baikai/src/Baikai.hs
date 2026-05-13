-- | Top-level entry point for the baikai library.
--
--   This is a starter stub: it exposes a single `greet` function so the
--   freshly generated project compiles and has something for the test
--   suite to exercise. Replace it with your real public API as the
--   library grows.
module Baikai
  ( greet
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Produce a friendly greeting for the given subject.
greet :: Text -> Text
greet who = T.pack "Hello, " <> who <> T.pack "!"
