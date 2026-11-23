-- | Read and review invocation-local Codex hooks with the native app-server.
-- A policy-bearing caller should keep the preflighted thread alive until its
-- turn finishes, so configuration changes cannot swap the verified handlers.
module Baikai.Provider.OpenAI.ReviewedHooks
  ( CodexHooks,
    parseCodexHooks,
    CodexHookReview (..),
    reviewCodexHooks,
    reviewCodexHooksInTerminal,
    withReviewedCodexHooks,
    ReviewedCodexThread,
    CodexHookTurn (..),
    runReviewedCodexTurn,
  )
where

import Baikai.Agent (AgentCapability (..))
import Baikai.Provider.Cli.Process.Internal (withOwnedProcess)
import Baikai.Provider.OpenAI.HookEvidence
  ( CodexPreToolUse (..),
    HookOutcome (..),
    parsePreToolUseCompletion,
    requireReviewedPreToolUseHook,
  )
import Control.Concurrent.MVar (MVar, newMVar, tryTakeMVar)
import Control.Exception (Exception, IOException, catch, throwIO, try)
import Control.Monad (unless, void, when)
import Data.Aeson (Object, Value (..), encode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (nub)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import System.Directory (canonicalizePath, doesFileExist, makeAbsolute)
import System.IO (Handle, hFlush, hIsTerminalDevice, stderr, stdin)
import System.Process qualified as Process
import System.Timeout (timeout)

data CodexHooks = CodexHooks !Value ![HookDeclaration]

data HookDeclaration = HookDeclaration
  { matcher :: !(Maybe Text),
    command :: !Text,
    timeoutSec :: !(Maybe Int),
    statusMessage :: !(Maybe Text)
  }

-- | Accept only a native hooks file with synchronous PreToolUse command
-- handlers. Keep the provider input in memory after parsing.
parseCodexHooks :: BS.ByteString -> Either Text CodexHooks
parseCodexHooks bytes = do
  value <- either (const (Left "Codex hooks file must contain valid JSON.")) Right (Aeson.eitherDecodeStrict' bytes)
  runParser parse value
  where
    parse = withObject "Codex hooks file" $ \file -> do
      onlyKeys ["hooks"] file
      hooks <- file .: "hooks"
      onlyKeys ["PreToolUse"] hooks
      groups <- hooks .: "PreToolUse" :: Parser [Value]
      declarations <- concat <$> traverse parseGroup groups
      when (null declarations) (fail "PreToolUse must contain at least one handler")
      pure (CodexHooks (Object hooks) declarations)

    parseGroup = withObject "PreToolUse entry" $ \entry -> do
      onlyKeys ["matcher", "hooks"] entry
      match <- entry .:? "matcher"
      handlers <- entry .: "hooks" :: Parser [Value]
      when (null handlers) (fail "PreToolUse entry must contain at least one handler")
      traverse (parseHandler match) handlers

    parseHandler match = withObject "PreToolUse handler" $ \handler -> do
      onlyKeys ["type", "command", "async", "timeout", "statusMessage"] handler
      kind <- handler .: "type"
      asynchronous <- handler .:? "async"
      unless (kind == ("command" :: Text) && asynchronous /= Just True) $
        fail "expected a synchronous command handler"
      cmd <- handler .: "command"
      when (Text.null (Text.strip cmd) || Text.any (== '\0') cmd) $
        fail "expected a nonblank command without NUL characters"
      seconds <- handler .:? "timeout"
      when (any (<= 0) seconds) (fail "hook timeout must be positive")
      HookDeclaration match cmd seconds <$> handler .:? "statusMessage"

    onlyKeys allowed obj =
      unless (all (`elem` allowed) (KeyMap.keys obj)) $
        fail "contains an unsupported field"

data CodexHookReview = CodexHookReview
  { nativeKey :: !Text,
    nativeHash :: !Text,
    nativeMatcher :: !(Maybe Text),
    nativeCommand :: !Text,
    nativeTimeoutSec :: !Int,
    nativeStatusMessage :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data Rpc = Rpc !Handle !Handle !(IORef Int)

data ReviewedCodexThread = ReviewedCodexThread !Rpc !Text !(MVar ())

-- | A completed, attributed turn. An empty block list is positive
-- evidence that this turn reported no blocks. A failed or interrupted
-- turn, or a failed/stopped gate, returns an error instead.
data CodexHookTurn = CodexHookTurn
  { answer :: !Text,
    blockedHooks :: ![CodexPreToolUse]
  }
  deriving stock (Eq, Show)

newtype HookPolicyError = HookPolicyError Text
  deriving stock (Show)

instance Exception HookPolicyError

-- | Review the exact effective native declarations. The callback implements
-- the operator interaction. A declined review or a file changed while the
-- operator was deciding leaves the trust store untouched.
reviewCodexHooks ::
  FilePath ->
  FilePath ->
  CodexHooks ->
  ([CodexHookReview] -> IO Bool) ->
  IO (Either Text Bool)
reviewCodexHooks executable cwd hooks confirm = runHookAction $
  withAppServer executable cwd Nothing $ \rpc -> do
    thread <- startThread rpc cwd AgentReadOnly Nothing [] hooks
    inventory <- rpcRequest rpc "hooks/list" (object ["threadId" .= thread])
    rows <- parseOrFail (parseInventory hooks) inventory
    let pending = [entry | (trust, entry) <- rows, trust /= "trusted"]
    if null pending
      then pure True
      else do
        accepted <- confirm pending
        when accepted $ do
          -- Use the same native config write as the Codex TUI. It merges
          -- only the exact reviewed entries into the user's hook state.
          let trust = object [Key.fromText (nativeKey row) .= object ["trusted_hash" .= nativeHash row] | row <- pending]
          void $
            rpcRequest rpc "config/batchWrite" $
              object
                [ "edits" .= [object ["keyPath" .= ("hooks.state" :: Text), "value" .= trust, "mergeStrategy" .= ("upsert" :: Text)]],
                  "reloadUserConfig" .= True
                ]
        pure accepted

-- | Present Codex's native review in the caller's terminal and require an
-- explicit answer before writing trust. The file must stay unchanged while
-- the operator reads the prompt.
reviewCodexHooksInTerminal :: FilePath -> FilePath -> FilePath -> IO (Either Text Bool)
reviewCodexHooksInTerminal executable cwd requested = do
  interactive <- hIsTerminalDevice stdin
  visible <- hIsTerminalDevice stderr
  if interactive && visible
    then do
      path <- makeAbsolute requested
      bytes <- readFileBytes path
      case bytes of
        Left err -> pure (Left err)
        Right original -> case parseCodexHooks original of
          Left err -> pure (Left err)
          Right hooks -> reviewCodexHooks executable cwd hooks (confirm path original)
    else pure (Left "Codex hooks must be reviewed in a terminal.")
  where
    readFileBytes path = do
      result <- try @IOException $ do
        exists <- doesFileExist path
        unless exists (ioError (userError "expected a file"))
        BS.readFile path
      pure (either (const (Left ("Cannot read Codex hooks file " <> quoted path <> "."))) Right result)
    quoted :: (Show a) => a -> Text
    quoted = Text.pack . show
    confirm path original pending = do
      TextIO.hPutStrLn stderr ("Review Codex hooks in " <> quoted path <> " for " <> quoted cwd <> ".")
      TextIO.hPutStrLn stderr "Reviewed commands can run outside the sandbox. Codex reviews the declaration and does not fingerprint scripts it invokes."
      mapM_ display pending
      TextIO.hPutStr stderr "Type yes to trust these declarations: "
      hFlush stderr
      reply <- try @IOException (TextIO.hGetLine stdin)
      if either (const False) (== "yes") reply
        then do
          current <- readFileBytes path
          case current of
            Right latest | latest == original -> pure True
            _ -> TextIO.hPutStrLn stderr "The hooks file changed during review. Open the updated file and try again." >> pure False
        else pure False
    display entry = do
      TextIO.hPutStrLn stderr ("  Matcher " <> maybe "all tools" quoted (nativeMatcher entry))
      TextIO.hPutStrLn stderr ("  Command " <> quoted (nativeCommand entry))
      TextIO.hPutStrLn stderr ("  Timeout " <> quoted (nativeTimeoutSec entry) <> " seconds")
      maybe (pure ()) (TextIO.hPutStrLn stderr . ("  Status " <>) . quoted) (nativeStatusMessage entry)

-- | Preflight a single thread before giving the application access to it.
-- No review state is written here. The caller supplies the native sandbox,
-- working directory, model, extra writable directories and optional TOML
-- value for the provider's skills.config setting.
withReviewedCodexHooks ::
  FilePath ->
  FilePath ->
  AgentCapability ->
  Maybe Text ->
  [FilePath] ->
  Maybe Text ->
  CodexHooks ->
  (ReviewedCodexThread -> IO a) ->
  IO (Either Text a)
withReviewedCodexHooks executable cwd sandbox model dirs skills hooks use = runHookAction $
  withAppServer executable cwd skills $ \rpc -> do
    thread <- startThread rpc cwd sandbox model dirs hooks
    inventory <- rpcRequest rpc "hooks/list" (object ["threadId" .= thread])
    rows <- parseOrFail (parseInventory hooks) inventory
    unless (all ((== "trusted") . fst) rows) $
      policyError "Codex requires review for the current hooks."
    mapM_ (\(_, row) -> parseOrFail (requireReviewedPreToolUseHook (nativeKey row) (nativeHash row)) inventory) rows
    once <- newMVar ()
    use (ReviewedCodexThread rpc thread once)

-- | Run one prompt in the preflighted thread. Consume the native stream
-- until the matching terminal event, preserving refusals even on success.
-- The owning process scope cleans up on cancellation.
runReviewedCodexTurn ::
  ReviewedCodexThread ->
  Text ->
  Maybe Text ->
  Maybe Value ->
  IO (Either Text CodexHookTurn)
runReviewedCodexTurn (ReviewedCodexThread rpc thread once) prompt effort schema = runHookAction $ do
  available <- tryTakeMVar once
  unless (available == Just ()) (policyError "This reviewed Codex thread has already started a turn.")
  let input = [object ["type" .= ("text" :: Text), "text" .= prompt, "text_elements" .= ([] :: [Value])]]
      params = object ["threadId" .= thread, "input" .= input, "effort" .= effort, "outputSchema" .= schema]
  (turn, pending) <- beginTurn params
  collect turn Set.empty [] pending
  where
    beginTurn params = do
      received <- timeout 30000000 $ do
        requestId <- sendRequest rpc "turn/start" params
        let await pending = do
              message <- rpcRead rpc
              case KeyMap.lookup "id" message of
                Just observed
                  | observed == requestId,
                    not (KeyMap.member "method" message),
                    Just result <- KeyMap.lookup "result" message -> do
                      turn <- parseOrFail (withObject "turn/start result" $ \obj -> obj .: "turn" >>= (.: "id")) result
                      pure (turn, reverse pending)
                Nothing -> await (message : pending)
                _ -> policyError "Codex could not start the reviewed turn."
        await []
      maybe (policyError "Timed out while starting the reviewed Codex turn.") pure received

    collect turn running blocks inbox = do
      (message, rest) <- case inbox of
        [] -> (,[]) <$> rpcRead rpc
        first : remaining -> pure (first, remaining)
      event <- parseOrFail parseTurnEvent (Object message)
      case event of
        Nothing -> collect turn running blocks rest
        Just (EventHookStart owner turnId identifier)
          | owner == thread && turnId == turn ->
              if Set.member identifier running
                then policyError "Codex reported a duplicate PreToolUse start."
                else collect turn (Set.insert identifier running) blocks rest
        Just (EventHookFinish completion)
          | threadId completion == thread && turnId completion == turn -> do
              let identifier = runId completion
              unless (Set.member identifier running) (policyError "Codex reported a PreToolUse completion without its start.")
              let remaining = Set.delete identifier running
              case outcome completion of
                Completed -> collect turn remaining blocks rest
                Blocked -> collect turn remaining (completion : blocks) rest
                Failed -> policyError "A Codex PreToolUse hook failed. Inspect the workspace and retry with a working gate."
                Stopped -> policyError "A Codex PreToolUse hook stopped before it could complete."
        Just (EventTurnEnd owner turnId status items)
          | owner == thread && turnId == turn -> do
              unless (status == "completed" && Set.null running) $
                policyError "Codex ended the turn without complete hook evidence."
              answers <- traverse (parseOrFail parseAnswer) items
              case reverse [answerText | Just answerText <- answers] of
                final : _ -> pure (CodexHookTurn final (reverse blocks))
                [] -> policyError "Codex finished without a final assistant message."
        Just (EventCommandDeclined owner turnId identifier)
          | owner == thread && turnId == turn ->
              policyError ("Codex declined command item " <> identifier <> ". Inspect the workspace and policy before retrying.")
        _ -> collect turn running blocks rest

    parseAnswer = withObject "item" $ \item -> do
      kind <- item .: "type"
      if kind == ("agentMessage" :: Text)
        then Just <$> item .: "text"
        else pure Nothing

data TurnEvent
  = EventHookStart !Text !Text !Text
  | EventHookFinish !CodexPreToolUse
  | EventTurnEnd !Text !Text !Text ![Value]
  | EventCommandDeclined !Text !Text !Text

parseTurnEvent :: Value -> Parser (Maybe TurnEvent)
parseTurnEvent = withObject "app-server event" $ \message -> do
  when (KeyMap.member "id" message) (fail "unexpected request during reviewed Codex turn")
  method <- message .: "method" :: Parser Text
  case method of
    "hook/completed" -> fmap EventHookFinish <$> parsePreToolUseCompletion (Object message)
    "hook/started" -> do
      params <- message .: "params"
      run <- params .: "run"
      event <- run .: "eventName"
      if event == ("preToolUse" :: Text)
        then Just <$> (EventHookStart <$> params .: "threadId" <*> params .: "turnId" <*> run .: "id")
        else pure Nothing
    "turn/completed" -> do
      params <- message .: "params"
      turn <- params .: "turn"
      Just <$> (EventTurnEnd <$> params .: "threadId" <*> turn .: "id" <*> turn .: "status" <*> turn .: "items")
    "item/completed" -> do
      params <- message .: "params"
      item <- params .: "item"
      kind <- item .: "type" :: Parser Text
      status <- item .:? "status" :: Parser (Maybe Text)
      if kind `elem` ["commandExecution", "fileChange"] && status == Just "declined"
        then Just <$> (EventCommandDeclined <$> params .: "threadId" <*> params .: "turnId" <*> item .: "id")
        else pure Nothing
    _ -> pure Nothing

parseInventory :: CodexHooks -> Value -> Parser [(Text, CodexHookReview)]
parseInventory (CodexHooks _ declarations) = withObject "hooks/list result" $ \result -> do
  rows <- result .: "data"
  row <- case rows of
    [entry] -> pure entry
    _ -> fail "expected one thread's hook inventory"
  errors <- row .: "errors"
  warnings <- row .: "warnings"
  unless (null (errors :: [Value]) && null (warnings :: [Value])) $
    fail "Codex reported hook inventory diagnostics"
  hooks <- row .: "hooks"
  let supplied = filter ((== Just (String "sessionFlags")) . KeyMap.lookup "source") hooks
  unless (length supplied == length declarations) $
    fail "effective hook inventory differs from the supplied file"
  observed <- traverse checkHook (zip declarations supplied)
  unless (Set.size (Set.fromList (map (nativeKey . snd) observed)) == length observed) $
    fail "Codex returned duplicate hook keys"
  pure observed
  where
    checkHook (expected, hook) = do
      event <- hook .: "eventName"
      handler <- hook .: "handlerType"
      enabled <- hook .: "enabled"
      async <- hook .: "async"
      trust <- hook .: "trustStatus"
      unless ((event, handler) == (("preToolUse", "command") :: (Text, Text)) && enabled && not async) $
        fail "expected an enabled synchronous PreToolUse command"
      unless (trust `elem` (["trusted", "untrusted", "modified"] :: [Text])) $
        fail "Codex reported an unsupported hook review state"
      review <-
        CodexHookReview
          <$> hook .: "key"
          <*> hook .: "currentHash"
          <*> hook .:? "matcher"
          <*> hook .: "command"
          <*> hook .: "timeoutSec"
          <*> hook .:? "statusMessage"
      unless
        ( nativeMatcher review == matcher expected
            && nativeCommand review == command expected
            && maybe True (== nativeTimeoutSec review) (timeoutSec expected)
            && nativeStatusMessage review == statusMessage expected
        )
        (fail "effective hook declaration differs from the supplied file")
      pure (trust, review)

startThread :: Rpc -> FilePath -> AgentCapability -> Maybe Text -> [FilePath] -> CodexHooks -> IO Text
startThread rpc cwd capability model dirs (CodexHooks hooks _) = do
  let wantsExtraRoots = capability == AgentEditWorkspace && not (null dirs)
  requestedRoots <- if wantsExtraRoots then traverse canonicalizePath dirs else pure []
  existingRoots <-
    if wantsExtraRoots
      then rpcRequest rpc "config/read" (object ["cwd" .= cwd, "includeLayers" .= False]) >>= parseOrFail parseWritableRoots
      else pure []
  let config =
        object $
          [ "hooks" .= hooks,
            -- The stable protocol's turn evidence covers this thread.
            "features" .= object ["multi_agent" .= False, "multi_agent_v2" .= False]
          ]
            <> [ "sandbox_workspace_write" .= object ["writable_roots" .= nub (existingRoots <> requestedRoots)]
               | wantsExtraRoots
               ]
  result <-
    rpcRequest rpc "thread/start" $
      object
        [ "cwd" .= cwd,
          "ephemeral" .= True,
          "sandbox" .= (sandbox :: Text),
          "approvalPolicy" .= ("never" :: Text),
          "model" .= model,
          "config" .= config
        ]
  (thread, actualRoots) <- parseOrFail checkThread result
  canonicalRoots <- if wantsExtraRoots then traverse canonicalizePath actualRoots else pure []
  unless (all (`elem` canonicalRoots) requestedRoots) $
    policyError "Codex did not give the reviewed session access to all requested directories."
  pure thread
  where
    (sandbox, effective) = case capability of
      AgentReadOnly -> ("read-only", "readOnly")
      AgentEditWorkspace -> ("workspace-write", "workspaceWrite")
      AgentFullAccess -> ("danger-full-access", "dangerFullAccess")

    parseWritableRoots = withObject "config/read result" $ \obj -> do
      current <- obj .: "config"
      workspace <- current .:? "sandbox_workspace_write"
      maybe (pure []) (fmap (maybe [] id) . (.:? "writable_roots")) workspace

    checkThread = withObject "thread/start result" $ \obj -> do
      policy <- obj .: "approvalPolicy"
      sandboxResult <- obj .: "sandbox"
      mode <- sandboxResult .: "type"
      unless ((policy, mode) == (("never", effective) :: (Text, Text))) $
        fail "Codex did not establish the requested sandbox and unattended approval policy"
      thread <- obj .: "thread" >>= (.: "id")
      roots <- sandboxResult .:? "writableRoots"
      pure (thread, maybe [] id roots)

runHookAction :: IO a -> IO (Either Text a)
runHookAction action =
  (either (\(HookPolicyError message) -> Left message) Right <$> try action)
    `catch` \(_ :: IOException) -> pure (Left "Could not communicate with the Codex app-server. Check that codex is on PATH and supports hooks/list.")

withAppServer :: FilePath -> FilePath -> Maybe Text -> (Rpc -> IO a) -> IO a
withAppServer executable cwd skills use =
  withOwnedProcess spec $ \mInput mOutput _ _ -> case (mInput, mOutput) of
    (Just input, Just output) -> do
      rpc <- Rpc input output <$> newIORef 0
      void $
        rpcRequest rpc "initialize" $
          object ["clientInfo" .= object ["name" .= ("baikai" :: Text), "version" .= ("1" :: Text)]]
      rpcSend rpc (object ["method" .= ("initialized" :: Text)])
      use rpc
    _ -> policyError "Could not open Codex app-server streams."
  where
    spec =
      (Process.proc executable (["app-server", "--stdio"] <> maybe [] (\value -> ["-c", "skills.config=" <> Text.unpack value]) skills))
        { Process.cwd = Just cwd,
          Process.std_in = Process.CreatePipe,
          Process.std_out = Process.CreatePipe,
          Process.std_err = Process.NoStream
        }

rpcSend :: Rpc -> Value -> IO ()
rpcSend (Rpc input _ _) value = do
  LBS.hPut input (encode value <> "\n")
  hFlush input

rpcRead :: Rpc -> IO Object
rpcRead (Rpc _ output _) = do
  line <- BS8.hGetLine output
  case Aeson.decodeStrict' line of
    Just (Object message) -> pure message
    _ -> policyError "Received an invalid message from the Codex app-server."

rpcRequest :: Rpc -> Text -> Value -> IO Value
rpcRequest rpc method params = do
  response <- timeout 30000000 $ do
    requestId <- sendRequest rpc method params
    waitForResponse requestId
  maybe (policyError ("Timed out waiting for Codex " <> method <> ".")) pure response
  where
    waitForResponse requestId = do
      message <- rpcRead rpc
      case KeyMap.lookup "id" message of
        Nothing -> waitForResponse requestId
        Just observed
          | observed == requestId,
            not (KeyMap.member "method" message),
            Just result <- KeyMap.lookup "result" message ->
              pure result
        _ -> policyError ("Codex could not complete " <> method <> ".")

sendRequest :: Rpc -> Text -> Value -> IO Value
sendRequest rpc@(Rpc _ _ counter) method params = do
  requestId <- atomicModifyIORef' counter (\previous -> let next = previous + 1 in (next, next))
  rpcSend rpc (object ["id" .= requestId, "method" .= method, "params" .= params])
  pure (Aeson.toJSON requestId)

runParser :: (Value -> Parser a) -> Value -> Either Text a
runParser parser = either (Left . Text.pack) Right . parseEither parser

parseOrFail :: (Value -> Parser a) -> Value -> IO a
parseOrFail parser = either policyError pure . runParser parser

policyError :: Text -> IO a
policyError = throwIO . HookPolicyError
