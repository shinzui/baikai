{-# LANGUAGE LambdaCase #-}

-- | Internal helpers shared by the CLI providers in @baikai-claude@
-- and @baikai-openai@.
--
-- Not re-exported from "Baikai"; vendor packages import this module
-- directly. This is an internal interface and is not covered by PVP
-- stability guarantees: names, types, and semantics may change in
-- minor releases. Application code should use the public provider
-- modules instead.
module Baikai.Provider.Cli.Internal
  ( renderPrompt,
    wrapSystemPrompt,
    maybeApply,
    decodeUtf8Lenient,
    trySync,

    -- * What a coding-agent CLI reported about its own run
    extractAgentMessage,
    CodexRunReport (..),
    parseCodexJsonlStream,
    ClaudeCliReport (..),
    decodeClaudeCliResult,

    -- * What baikai knows about the process it launched
    ExecutableIdentity (..),
    executableIdentity,

    -- * Evidence envelopes and strength
    argvEnvelope,
    cliResponseEnvelope,
    subprocessStrength,
  )
where

import Baikai.Content
  ( AssistantContent (..),
    TextContent (..),
    ToolResultContent (..),
    UserContent (..),
  )
import Baikai.Context (Context)
import Baikai.Cost (Cost (..), zeroCost, zeroCostBreakdown)
import Baikai.Error (BaikaiError, decodeError)
import Baikai.Evidence (EvidenceStrength (..), Observed (..))
import Baikai.Message
  ( AssistantPayload (..),
    Message (..),
    ToolResultPayload (..),
    UserPayload (..),
  )
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (Usage (..))
import Control.Applicative ((<|>))
import Control.Exception
  ( SomeAsyncException (..),
    SomeException,
    fromException,
    throwIO,
    try,
  )
import Control.Lens ((%~), (&), (.~), (^.))
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither, parseMaybe, (.:), (.:?))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Scientific qualified as Scientific
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Word (Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import System.Directory qualified as Directory
import System.Exit (ExitCode (..))
import System.FilePath (isPathSeparator)
import System.IO.Unsafe (unsafePerformIO)
import System.Process qualified as Process
import System.Timeout (timeout)

-- | Flatten a 'Context'\'s messages into a single prompt string
-- suitable for a one-shot CLI invocation.
--
-- A context whose only message is a 'UserMessage' with a single
-- 'UserText' block is returned verbatim. Anything else is joined
-- with @[role]:@ markers so the CLI still sees a coherent
-- transcript. Image content and tool calls are dropped (CLI
-- providers do not participate in tool use; image bytes cannot be
-- passed verbatim through a CLI). The masterplan documents CLI
-- providers as text-only and tool-incapable.
renderPrompt :: Context -> Text
renderPrompt ctx =
  let msgs = Vector.toList (ctx ^. #messages)
   in case msgs of
        [UserMessage UserPayload {content = uc}]
          | [UserText (TextContent t)] <- Vector.toList uc ->
              t
        _ -> Text.intercalate "\n" (fmap tag msgs)
  where
    tag :: Message -> Text
    tag (UserMessage UserPayload {content = uc}) =
      "[user]: " <> flattenUser uc
    tag (AssistantMessage AssistantPayload {content = ac}) =
      "[assistant]: " <> flattenAssistant ac
    tag (ToolResultMessage ToolResultPayload {toolName = n, content = trc}) =
      "[tool:" <> n <> "]: " <> flattenToolResult trc

    flattenUser :: Vector UserContent -> Text
    flattenUser = Text.concat . Vector.toList . Vector.mapMaybe pickU
      where
        pickU (UserText (TextContent t)) = Just t
        pickU _ = Nothing

    flattenAssistant :: Vector AssistantContent -> Text
    flattenAssistant = Text.concat . Vector.toList . Vector.mapMaybe pickA
      where
        pickA (AssistantText (TextContent t)) = Just t
        pickA _ = Nothing

    flattenToolResult :: Vector ToolResultContent -> Text
    flattenToolResult = Text.concat . Vector.toList . Vector.mapMaybe pickT
      where
        pickT (ToolResultText (TextContent t)) = Just t
        pickT _ = Nothing

-- | Wrap a rendered prompt with a system-instruction preamble for
-- CLIs that expose no native system-prompt flag. 'Nothing' and
-- blank system prompts return the body unchanged. The textual
-- format is shared by the codex batch provider and the codex
-- interactive launcher.
wrapSystemPrompt :: Maybe Text -> Text -> Text
wrapSystemPrompt msp body = case Text.strip <$> msp of
  Nothing -> body
  Just "" -> body
  Just sp ->
    Text.concat
      [ "System instructions:\n",
        sp,
        "\n\nUser request:\n",
        body
      ]

-- | @maybeApply ma f x@ applies @f a x@ when @ma = Just a@,
-- otherwise returns @x@. Useful for threading optional configuration
-- into a cradle pipeline.
maybeApply :: Maybe a -> (a -> b -> b) -> b -> b
maybeApply Nothing _ b = b
maybeApply (Just a) f b = f a b

-- | Decode UTF-8 bytes leniently, replacing invalid sequences with
-- U+FFFD. Used for surfacing CLI stderr in a
-- 'Baikai.Error.ProcessFailure' error.
decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = Text.decodeUtf8With Text.lenientDecode

-- | 'Control.Exception.try' that catches synchronous failures and lets
-- an asynchronous one through.
--
-- A subprocess provider turns a failed launch into an error-shaped
-- 'Baikai.Response.Response' rather than an exception, so it has to
-- catch broadly; swallowing a cancellation or a timeout while doing so
-- would make the caller's own control flow unreliable.
trySync :: IO a -> IO (Either SomeException a)
trySync action = do
  r <- try action
  case r of
    Left e
      | Just (SomeAsyncException _) <- (fromException e :: Maybe SomeAsyncException) ->
          throwIO e
      | otherwise -> pure (Left e)
    Right a -> pure (Right a)

-- ============================================================
-- Codex event-stream parsing
-- ============================================================

-- | What a @codex exec --json@ run reported about itself, beyond the
-- assistant text.
--
-- Every field but 'message' is optional because the tool's event schema
-- has changed across codex versions and a missing field is a genuine
-- absence rather than a parse failure. A field that is 'Nothing' here
-- must be recorded as 'Baikai.Evidence.Unobserved' downstream and must
-- never be filled in from the request.
data CodexRunReport = CodexRunReport
  { -- | The concatenated text of every @agent_message@ event.
    message :: !Text,
    -- | Codex's own handle for the conversation, from the
    -- thread-start event.
    threadId :: !(Maybe Text),
    -- | The model codex named alongside its token accounting. See
    -- 'codexTurn' for why it is only ever read from such an event.
    reportedModel :: !(Maybe Text),
    -- | The token counts codex reported, normalized into baikai's
    -- disjoint 'Usage' convention.
    usage :: !(Maybe Usage)
  }
  deriving stock (Eq, Show, Generic)

-- | The accumulator 'parseCodexJsonlStream' folds events into.
--
-- Separate from 'CodexRunReport' only because the message text arrives
-- in pieces and is kept reversed until the fold finishes.
data CodexAccumulator = CodexAccumulator
  { messages :: ![Text],
    threadId :: !(Maybe Text),
    reportedModel :: !(Maybe Text),
    usage :: !(Maybe Usage)
  }
  deriving stock (Generic)

emptyCodexAccumulator :: CodexAccumulator
emptyCodexAccumulator =
  CodexAccumulator
    { messages = [],
      threadId = Nothing,
      reportedModel = Nothing,
      usage = Nothing
    }

-- | Consume a stream of stdout bytes from @codex exec --json@, split on
-- newlines, decode each line as JSON, and fold the events into what the
-- run reported about itself.
--
-- A line that is not valid JSON is skipped rather than failing the run:
-- codex writes progress chatter to stderr, but a future version writing
-- a non-JSON line to stdout must not turn a completed model call into a
-- decode error. A last line with no trailing newline is still parsed.
--
-- Lines are cut out of each chunk with 'BS.elemIndex' and 'BS.splitAt',
-- which are a scan and a constant-time slice, and the pieces of a line
-- that spans a chunk boundary are carried as a reversed list and joined
-- once, when its newline arrives. Every byte is therefore copied a
-- bounded number of times however long the line is. The obvious
-- alternative — unpacking each chunk into a stream of bytes and
-- appending them one at a time with 'BS.snoc' — copies the whole
-- accumulator per byte, which is quadratic in line length: a codex event
-- carrying a two-million-character message cost on the order of a
-- trillion byte moves and in practice never finished.
parseCodexJsonlStream :: Stream IO ByteString -> IO CodexRunReport
parseCodexJsonlStream chunks = do
  (folded, pending) <-
    Stream.fold (Fold.foldl' absorbChunk (emptyCodexAccumulator, [])) chunks
  -- Whatever follows the last newline. An empty remainder — the ordinary
  -- case, because codex terminates every line — decodes to Nothing and
  -- is skipped, exactly as a non-JSON line is.
  let acc = absorbLine folded (joinPieces pending)
  pure
    CodexRunReport
      { message = Text.concat (reverse (acc ^. #messages)),
        threadId = acc ^. #threadId,
        reportedModel = acc ^. #reportedModel,
        usage = acc ^. #usage
      }
  where
    absorbChunk (acc, pending) chunk = case BS.elemIndex newlineByte chunk of
      Nothing -> (acc, chunk : pending)
      Just at ->
        let (piece, rest) = BS.splitAt at chunk
            acc' = absorbLine acc (joinPieces (piece : pending))
         in absorbChunk (acc', []) (BS.drop 1 rest)
    absorbLine acc line = maybe acc (absorbCodexEvent acc) (Aeson.decodeStrict line)
    joinPieces = BS.concat . reverse

-- | Fold one decoded codex event into the accumulator.
--
-- The identifier keeps the __first__ value it sees, because the
-- thread-start event names the conversation and nothing later should
-- rename it. The token accounting keeps the __last__, because codex
-- emits one accounting event per turn and the final one is the one that
-- describes the completed run; summing them would double-count a
-- cumulative counter.
absorbCodexEvent :: CodexAccumulator -> Value -> CodexAccumulator
absorbCodexEvent acc v =
  withTurn
    ( acc
        & #messages %~ maybe id (:) (extractAgentMessage v)
        & #threadId %~ (<|> extractThreadId v)
    )
  where
    withTurn a = case codexTurn v of
      Nothing -> a
      Just (reported, counted) ->
        a
          & #usage .~ Just counted
          & #reportedModel .~ reported

-- | Best-effort extractor for the assistant text inside a single
-- Codex @--json@ event. See the original implementation's
-- documentation for the schema variants accepted.
extractAgentMessage :: Value -> Maybe Text
extractAgentMessage = parseMaybe parser
  where
    parser = Aeson.withObject "codex-event" $ \o -> do
      mItem <- o .:? "item"
      case (mItem :: Maybe Value) of
        Just (Aeson.Object io) -> do
          ty <- io .:? "type"
          case (ty :: Maybe Text) of
            Just "agent_message" -> pickText io
            _ -> tryMsg o
        _ -> tryMsg o

    tryMsg o = do
      mInner <- o .:? "msg"
      case (mInner :: Maybe Value) of
        Just (Aeson.Object io) -> do
          ty <- io .:? "type"
          case (ty :: Maybe Text) of
            Just "agent_message" -> pickText io
            _ -> fail "not an agent_message"
        _ -> tryFlat o

    tryFlat o = do
      ty <- o .:? "type"
      case (ty :: Maybe Text) of
        Just "agent_message" -> pickText o
        _ -> fail "not an agent_message"

    pickText o = case KeyMap.lookup "message" o of
      Just (Aeson.String t) -> pure t
      _ -> case KeyMap.lookup "text" o of
        Just (Aeson.String t) -> pure t
        _ -> fail "no payload"

-- | Apply a lookup to a codex event object, then to its nested @item@
-- and @msg@ objects, taking the first hit.
--
-- Codex has spelled its events all three ways across versions, which is
-- why 'extractAgentMessage' already tolerates each one. Every extractor
-- below inherits the same tolerance from here rather than repeating it.
inCodexEvent :: (KeyMap Value -> Maybe a) -> Value -> Maybe a
inCodexEvent f = \case
  Object o -> f o <|> nested o "item" <|> nested o "msg"
  _ -> Nothing
  where
    nested o k = case KeyMap.lookup k o of
      Just (Object io) -> f io
      _ -> Nothing

-- | Codex's own identifier for the conversation this run belongs to.
--
-- @codex-cli 0.146.0@ spells it @thread_id@ on a @thread.started@
-- event; older versions spelled the same thing @session_id@ and
-- @conversation_id@, and all three are accepted because a recorded
-- fixture from any of them must still parse.
extractThreadId :: Value -> Maybe Text
extractThreadId = inCodexEvent (firstString ["thread_id", "session_id", "conversation_id"])

-- | The token accounting from one codex event, and the model named on
-- that same event.
--
-- The model is deliberately read __only__ from an event that also
-- carries token counts. An event naming a model beside its token
-- accounting is saying which model consumed them, which is an
-- observation; an event naming a model anywhere else could just as
-- easily be echoing the @--model@ flag baikai passed in, and recording
-- a request echo as an observation is precisely the conflation this
-- record exists to prevent. At @codex-cli 0.146.0@ no event names a
-- model at all, so this yields 'Nothing' today and will pick one up
-- only if codex starts reporting one where it belongs.
codexTurn :: Value -> Maybe (Maybe Text, Usage)
codexTurn = inCodexEvent $ \o -> case KeyMap.lookup "usage" o of
  Just (Object u)
    | any (`KeyMap.member` u) codexUsageKeys ->
        Just (firstString ["model"] o, codexUsage u)
  _ -> Nothing

codexUsageKeys :: [Key]
codexUsageKeys =
  [ "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens"
  ]

-- | Normalize codex's usage block into baikai's disjoint convention.
--
-- Codex reports OpenAI-style inclusive prompt counts: @input_tokens@
-- contains @cached_input_tokens@, which is why codex's own display
-- arithmetic subtracts one from the other to show non-cached input. The
-- subtraction is clamped at zero because 'Natural' subtraction throws
-- on underflow.
--
-- @cache_write_input_tokens@ is carried through unmodified rather than
-- also subtracted. It is not part of the inclusive prompt total in any
-- codex version this repository has observed, and undercounting input
-- would be the worse of the two errors: it silently shrinks a call that
-- actually consumed the tokens.
codexUsage :: KeyMap Value -> Usage
codexUsage u =
  let prompt = natField u "input_tokens"
      cached = natField u "cached_input_tokens"
      written = natField u "cache_write_input_tokens"
      out = natField u "output_tokens"
      nonCached = if cached >= prompt then 0 else prompt - cached
   in Usage
        { inputTokens = nonCached,
          outputTokens = out,
          cacheReadTokens = cached,
          cacheWriteTokens = written,
          reasoningTokens = natFieldMaybe u "reasoning_output_tokens",
          totalTokens = nonCached + out + cached + written,
          cost = zeroCost
        }

newlineByte :: Word8
newlineByte = 0x0a

-- ============================================================
-- Claude CLI result parsing
-- ============================================================

-- | What a @claude -p --output-format json@ run reported about itself.
--
-- The Haskell field is 'isError' where the tool's JSON field is
-- @is_error@: the record follows Haskell naming and the parser does the
-- mapping. 'reportedModel' and 'usage' are optional because the tool's
-- result schema varies by version, and an absent field must degrade to
-- 'Baikai.Evidence.Unobserved' rather than fail the decode.
data ClaudeCliReport = ClaudeCliReport
  { -- | The assistant's answer, or the error text when 'isError'.
    result :: !Text,
    isError :: !Bool,
    -- | The tool's own handle for the conversation.
    sessionId :: !(Maybe Text),
    -- | The model the tool reported as having consumed tokens. See
    -- 'soleModelUsageKey'.
    reportedModel :: !(Maybe Text),
    -- | The token counts and reported cost, when the tool included a
    -- usage block.
    usage :: !(Maybe Usage)
  }
  deriving stock (Eq, Show, Generic)

-- | Decode @claude -p --output-format json@ stdout.
--
-- The tool emits either a bare result object or — as it does at version
-- 2.1.222 — an array of events from which the one whose @type@ is
-- @result@ is the terminal record. Both shapes are accepted because
-- both have shipped.
decodeClaudeCliResult :: ByteString -> Either BaikaiError ClaudeCliReport
decodeClaudeCliResult bs = case Aeson.eitherDecodeStrict bs of
  Left err -> Left (decodeError (Text.pack err))
  Right (Array events) -> case findResultEvent events of
    Nothing -> Left (decodeError "claude -p: no result event in stdout array")
    Just ev -> parseResultEvent ev
  Right v@(Object _) -> parseResultEvent v
  Right _ -> Left (decodeError "claude -p: expected JSON object or array")

findResultEvent :: Vector Value -> Maybe Value
findResultEvent = Vector.find isResult
  where
    isResult (Object o) = case KeyMap.lookup "type" o of
      Just (String "result") -> True
      _ -> False
    isResult _ = False

parseResultEvent :: Value -> Either BaikaiError ClaudeCliReport
parseResultEvent v = case parseEither parser v of
  Left err -> Left (decodeError (Text.pack err))
  Right r -> Right r
  where
    parser = Aeson.withObject "claude-cli-result" $ \o -> do
      body <- o .: "result"
      failed <- o .: "is_error"
      session <- o .:? "session_id"
      pure
        ClaudeCliReport
          { result = body,
            isError = failed,
            sessionId = session,
            reportedModel = KeyMap.lookup "modelUsage" o >>= soleModelUsageKey,
            usage = claudeUsage o
          }

-- | The model @claude@ reported as having consumed tokens.
--
-- Read from the keys of the result event's @modelUsage@ map, which
-- names every model that actually billed tokens on this run — and
-- names it as the tool spells it, including a context-window variant
-- marker such as @[1m]@, because truncating that to the canonical name
-- would discard a real distinction between two things baikai can
-- request separately.
--
-- Exactly one key is an unambiguous statement of which model ran.
-- Several keys means several models did, and 'Baikai.Evidence' has one
-- 'Baikai.Evidence.observedModel' slot; picking one of them arbitrarily
-- would be a fabrication of specificity, so nothing is recorded.
soleModelUsageKey :: Value -> Maybe Text
soleModelUsageKey = \case
  Object mu -> case KeyMap.keys mu of
    [k] -> Just (Key.toText k)
    _ -> Nothing
  _ -> Nothing

-- | The token counts and reported cost from a @claude@ result event.
--
-- The tool reports Anthropic's already-disjoint prompt classes —
-- @input_tokens@ excludes both cache counters — so nothing is
-- subtracted here, unlike 'codexUsage'.
--
-- @total_cost_usd@ becomes 'Baikai.Cost.Cost'\'s @usd@ with an empty
-- per-class breakdown, because the tool reports one total and no
-- breakdown. Reporting the tool's own figure is the same correction as
-- reporting its own token counts: a hardcoded zero says the call was
-- free, which is a claim the tool never made.
claudeUsage :: KeyMap Value -> Maybe Usage
claudeUsage o = case KeyMap.lookup "usage" o of
  Just (Object u)
    | any (`KeyMap.member` u) claudeUsageKeys ->
        let i = natField u "input_tokens"
            out = natField u "output_tokens"
            cr = natField u "cache_read_input_tokens"
            cw = natField u "cache_creation_input_tokens"
         in Just
              Usage
                { inputTokens = i,
                  outputTokens = out,
                  cacheReadTokens = cr,
                  cacheWriteTokens = cw,
                  reasoningTokens = Nothing,
                  totalTokens = i + out + cr + cw,
                  cost = reportedCost
                }
  _ -> Nothing
  where
    reportedCost = case KeyMap.lookup "total_cost_usd" o of
      Just (Number n) | n > 0 -> Cost {usd = toRational n, breakdown = zeroCostBreakdown}
      _ -> zeroCost

claudeUsageKeys :: [Key]
claudeUsageKeys =
  [ "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens"
  ]

-- ============================================================
-- Shared JSON field readers
-- ============================================================

-- | The first of the named keys whose value is a non-empty JSON string.
firstString :: [Key] -> KeyMap Value -> Maybe Text
firstString keys o =
  listToMaybe
    [t | k <- keys, Just (String t) <- [KeyMap.lookup k o], not (Text.null t)]

-- | A non-negative whole number from a JSON field, or zero.
--
-- A missing, negative, fractional, or absurdly large value reads as
-- zero rather than throwing: a token counter is describing a completed
-- model call, and no shape of counter is worth failing that call over.
natField :: KeyMap Value -> Key -> Natural
natField o k = fromMaybe 0 (natFieldMaybe o k)

-- | 'natField', but distinguishing an absent field from a reported
-- zero. 'Baikai.Usage.Usage'\'s @reasoningTokens@ needs the
-- distinction; its other counters do not.
natFieldMaybe :: KeyMap Value -> Key -> Maybe Natural
natFieldMaybe o k = case KeyMap.lookup k o of
  Just (Number n) -> case Scientific.toBoundedInteger n :: Maybe Int of
    Just i | i >= 0 -> Just (fromIntegral i)
    _ -> Nothing
  _ -> Nothing

-- ============================================================
-- Executable identity
-- ============================================================

-- | Identity of the executable a subprocess provider ran.
data ExecutableIdentity = ExecutableIdentity
  { -- | The name or path as configured.
    configured :: !Text,
    -- | The absolute path it resolved to on @PATH@, when resolution
    --   succeeded.
    resolvedPath :: !(Maybe Text),
    -- | What the tool prints for @--version@, trimmed to its first
    --   non-blank line. 'Nothing' when the probe failed or the tool has
    --   no such flag; a failed probe is recorded as absent rather than
    --   failing the call, because the call itself may well have
    --   succeeded and the absence is itself accurate evidence.
    version :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Resolve and probe an executable, caching the result for the
-- lifetime of the process, keyed by the configured name.
--
-- Probing runs the tool once with @--version@. A version string is
-- stable for the lifetime of a baikai process in every realistic
-- deployment, and spawning an extra subprocess per model call would
-- roughly double the process cost of the cheapest possible call — so
-- the answer is cached, keyed by the configured name so a caller who
-- configures two different executables gets two correct answers.
--
-- Call this only from inside the evidence branch. A caller who never
-- asked for evidence must not pay for a process whose only purpose is
-- to describe a tool they were about to run anyway.
--
-- The probe is bounded by 'versionProbeMicros': a tool that hangs on
-- @--version@ must never be able to wedge a model call.
executableIdentity :: FilePath -> IO ExecutableIdentity
executableIdentity exe = do
  cached <- Map.lookup exe <$> readIORef executableIdentityCache
  case cached of
    Just identity -> pure identity
    Nothing -> do
      identity <- probeExecutable exe
      -- Insert only if still absent: two threads racing on the same
      -- executable must agree on one answer, and the first one written
      -- is as good as the second.
      atomicModifyIORef'
        executableIdentityCache
        (\m -> (Map.insertWith (\_ old -> old) exe identity m, ()))
      pure identity

probeExecutable :: FilePath -> IO ExecutableIdentity
probeExecutable exe = do
  resolved <- resolveExecutable exe
  probed <- maybe (pure Nothing) probeVersion resolved
  pure
    ExecutableIdentity
      { configured = Text.pack exe,
        resolvedPath = Text.pack <$> resolved,
        version = probed
      }

-- | Where a configured executable name actually points.
--
-- A name containing a path separator is a path and is checked
-- directly; a bare name is looked up on @PATH@. Doing the split here
-- rather than relying on 'Directory.findExecutable' to handle both
-- keeps the behaviour the same across @directory@ versions, which have
-- not always agreed on what a path-shaped argument means.
resolveExecutable :: FilePath -> IO (Maybe FilePath)
resolveExecutable exe
  | any isPathSeparator exe = do
      here <- Directory.doesFileExist exe
      if here then Just <$> Directory.makeAbsolute exe else pure Nothing
  | otherwise = Directory.findExecutable exe

probeVersion :: FilePath -> IO (Maybe Text)
probeVersion path = do
  outcome <- trySync (timeout versionProbeMicros (Process.readProcessWithExitCode path ["--version"] ""))
  pure $ case outcome of
    Right (Just (ExitSuccess, out, _)) -> firstNonBlankLine (Text.pack out)
    _ -> Nothing

-- | Five seconds.
--
-- The bound exists to stop a tool that /never/ answers from wedging a
-- model call, so any finite value solves the problem it is there for.
-- What a tighter bound buys is nothing; what it costs is a version
-- recorded as absent because the machine was busy when the probe ran.
-- Five seconds is paid at most once per executable per process, and
-- only on the pathological path.
versionProbeMicros :: Int
versionProbeMicros = 5000000

firstNonBlankLine :: Text -> Maybe Text
firstNonBlankLine = listToMaybe . filter (not . Text.null) . map Text.strip . Text.lines

-- | Resolved executable identities, keyed by the configured name.
--
-- The @unsafePerformIO@-plus-@NOINLINE@ idiom is the one
-- "Baikai.Provider.Registry" already uses for its global registry, so
-- the shape of a process-wide cache is the same wherever it appears in
-- this package.
executableIdentityCache :: IORef (Map FilePath ExecutableIdentity)
executableIdentityCache = unsafePerformIO (newIORef Map.empty)
{-# NOINLINE executableIdentityCache #-}

-- ============================================================
-- Evidence envelopes and strength
-- ============================================================

-- | The request envelope a subprocess provider hands to
-- 'Baikai.Evidence.Build.minimalEvidence': the rendered argument
-- vector, executable first, as a JSON array of strings.
--
-- This is the subprocess analogue of an API provider's request body,
-- and it is genuinely what crossed the boundary — there is no other
-- description of a process launch.
--
-- Both CLI providers place the prompt inside this vector, so
-- 'Baikai.Evidence.commitmentDigest' over it legitimately commits to
-- the prompt. 'Baikai.Evidence.configurationDigest' does not: its
-- projection admits named fields from an object and a JSON array has
-- none, so an argv envelope projects to @null@ and the configuration
-- digest reveals nothing about the command line at all. That is the
-- allow-list failing in the safe direction, which is what it is for.
argvEnvelope :: FilePath -> [String] -> Value
argvEnvelope exe args =
  Aeson.toJSON (map Text.pack (exe : args))

-- | What a subprocess call's response commitment digest commits to: the
-- assistant content, the stop reason, and the reported usage.
--
-- Spelled with the same three keys, in the same shapes, as the
-- Anthropic and OpenAI-compatible API transports build by hand in
-- @Baikai.Provider.Claude.Api@ and @Baikai.Provider.OpenAI.Api@. That
-- agreement is what lets a verifier holding a response recompute the
-- digest without first having to know which transport served it, so it
-- must not be allowed to drift.
--
-- A CLI provider produces exactly one text block and always stops with
-- 'Stop', which is why those two are fixed here rather than passed in.
cliResponseEnvelope :: Text -> Usage -> Value
cliResponseEnvelope body used =
  Aeson.object
    [ "content" .= Vector.singleton (AssistantText (TextContent body)),
      "stop_reason" .= Stop,
      "usage" .= used
    ]

-- | How much a subprocess call's evidence proves.
--
-- A coding-agent CLI that exits zero has demonstrated that it ran and
-- did not crash. It has not stated which model served the request, what
-- effort was applied, or whether the request reached the intended
-- provider at all — so a successful exit never raises the strength, and
-- the exit status is deliberately not an argument to this function.
-- Only a value the tool itself reported can raise it.
subprocessStrength ::
  -- | The session or thread identifier the tool reported.
  Observed Text ->
  -- | The model the tool reported, if it reports one at all.
  Observed Text ->
  EvidenceStrength
subprocessStrength sessionIdentifier reported =
  case (reported, sessionIdentifier) of
    (Observed _, Observed _) -> EvidenceModelObserved
    (_, Observed _) -> EvidenceCorrelated
    _ -> EvidenceRequestedOnly
