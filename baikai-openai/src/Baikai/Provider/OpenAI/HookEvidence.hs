-- | Read per-call evidence from the Codex app-server v2 notification stream.
-- Use this on a subscribed thread. The @codex exec --json@ transport has a
-- different schema and omits blocked pre-tool calls. A caller must verify
-- that its hooks are active with @hooks/list@ before starting the turn.
module Baikai.Provider.OpenAI.HookEvidence
  ( CodexPreToolUse (..),
    HookOutcome (..),
    requireReviewedPreToolUseHook,
    parsePreToolUseCompletion,
  )
where

import Control.Monad (filterM, unless)
import Data.Aeson (Object, Value, withObject, withText, (.:))
import Data.Aeson.Types (Parser)
import Data.Text (Text)

-- | A hook that completed normally can leave the tool decision to Codex.
-- Failed and stopped hooks require separate handling by a policy consumer.
data HookOutcome = Completed | Blocked | Failed | Stopped
  deriving stock (Eq, Show)

-- | The run identifier is opaque. Codex 0.171 exposes neither the command
-- arguments nor a separate tool-call identifier in this notification.
data CodexPreToolUse = CodexPreToolUse
  { threadId :: !Text,
    turnId :: !Text,
    runId :: !Text,
    outcome :: !HookOutcome
  }
  deriving stock (Eq, Show)

-- | Check one required synchronous command gate in the result of @hooks/list@
-- for the active thread. Supply the key and normalized hash from the reviewed
-- policy. Check every required gate before sending @turn/start@. This reads
-- the native review state and never grants trust or changes configuration.
requireReviewedPreToolUseHook :: Text -> Text -> Value -> Parser ()
requireReviewedPreToolUseHook key reviewedHash = withObject "hooks/list result" $ \result -> do
  rows <- result .: "data"
  row <- case rows of
    [entry] -> pure entry
    _ -> fail "expected the hook inventory for one thread"
  errors <- row .: "errors"
  unless (null (errors :: [Value])) (fail "Codex reported hook inventory errors")
  hooks <- row .: "hooks"
  matches <- filterM (fmap (== key) . (.: "key")) (hooks :: [Object])
  hook <- case matches of
    [match] -> pure match
    _ -> fail "expected one matching hook in the active thread"
  source <- hook .: "source"
  event <- hook .: "eventName"
  handler <- hook .: "handlerType"
  unless
    ((source, event, handler) == (("sessionFlags", "preToolUse", "command") :: (Text, Text, Text)))
    (fail "expected a thread-supplied PreToolUse command hook")
  enabled <- hook .: "enabled"
  async <- hook .: "async"
  unless (enabled && not async) (fail "the required hook must be enabled and synchronous")
  trust <- hook .: "trustStatus"
  current <- hook .: "currentHash"
  unless
    (trust == ("trusted" :: Text) && current == reviewedHash)
    (fail "the required hook needs review for its current declaration")

-- | Parse one app-server notification. Unrelated notifications yield
-- 'Nothing'. A malformed pre-tool completion or unknown terminal status
-- yields a parse error. An empty stream supplies no evidence of coverage.
parsePreToolUseCompletion :: Value -> Parser (Maybe CodexPreToolUse)
parsePreToolUseCompletion = withObject "app-server notification" $ \notification -> do
  method <- notification .: "method"
  if method /= ("hook/completed" :: Text)
    then pure Nothing
    else do
      params <- notification .: "params"
      run <- params .: "run"
      event <- run .: "eventName"
      if event /= ("preToolUse" :: Text)
        then pure Nothing
        else do
          thread <- params .: "threadId"
          turn <- params .: "turnId"
          identifier <- run .: "id"
          status <- run .: "status" >>= withText "preToolUse status" parseStatus
          pure (Just (CodexPreToolUse thread turn identifier status))
  where
    parseStatus "completed" = pure Completed
    parseStatus "blocked" = pure Blocked
    parseStatus "failed" = pure Failed
    parseStatus "stopped" = pure Stopped
    parseStatus _ = fail "unknown or nonterminal preToolUse completion status"
