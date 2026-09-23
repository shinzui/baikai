-- | The optparse-applicative adapter a consuming tool wires up as its
--   @kit@ subcommand.
--
--   'runKit' is the only function in @baikai-kit@ that exits the process;
--   see @docs/adr/0013-library-code-never-calls-exitfailure.md@.
module Baikai.Kit.Command
  ( KitCommand (..),
    OutputFormat (..),
    kitCommandParser,
    runKit,
    runKitCommand,
  )
where

import Baikai.Kit.Config (KitConfig, KitScope (..), scopeLabel)
import Baikai.Kit.Error (KitError (..), renderKitError)
import Baikai.Kit.Install
  ( OverwritePolicy (..),
    UpdateReport,
    installFrom,
    loadManifest,
    renderAvailable,
    renderUninstallReport,
    uninstallItem,
    updateKit,
  )
import Baikai.Kit.Json (listDocument, statusDocument, updateDocument)
import Baikai.Kit.Manifest (KitManifest, itemKind, itemName)
import Baikai.Kit.Repo (KitRepo, RepoRefresh (..), ensureKitRepo)
import Baikai.Kit.Status (StatusReport, UpstreamAvailability (..), installedCopies, kitStatus, renderStatusTable)
import Baikai.Prelude
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Options.Applicative
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (Handle, stderr, stdout)

-- | How @list@, @status@ and @update@ print their result: the terminal
--   table, or exactly one JSON document on stdout (see "Baikai.Kit.Json").
data OutputFormat
  = HumanOutput
  | JsonOutput
  deriving stock (Eq, Show)

data KitCommand
  = KitList !OutputFormat
  | -- | 'Nothing' asks the configured 'Baikai.Kit.Config.chooseItem'.
    KitInstall !(Maybe Text) !KitScope
  | KitUpdate !(Maybe Text) !OverwritePolicy !OutputFormat
  | KitUninstall !Text !KitScope
  | KitStatus !OutputFormat
  deriving stock (Eq, Show)

-- | The @kit@ subcommands. Takes the configuration so help text can name
--   the tool's own project directory.
kitCommandParser :: KitConfig -> Parser KitCommand
kitCommandParser config =
  hsubparser
    ( command "list" (info (KitList <$> formatParser) (progDesc "List available skills and subagents"))
        <> command "install" (info (installParser config) (progDesc "Install a skill or subagent"))
        <> command "update" (info updateParser (progDesc "Update installed skills and subagents"))
        <> command "uninstall" (info (uninstallParser config) (progDesc "Uninstall a skill or subagent"))
        <> command "status" (info (KitStatus <$> formatParser) (progDesc "Show installed skills and subagents"))
    )
    <|> pure (KitList HumanOutput)

-- | Run one verb and print its normal output. Never exits, so a consumer
--   that wants its own exit codes can map the 'KitError' itself.
runKitCommand :: KitConfig -> KitCommand -> IO (Either KitError ())
runKitCommand config = \case
  KitList HumanOutput -> withRepo HumanOutput $ \repo ->
    loadManifest (repo ^. #dir) `thenE` \manifest ->
      printed (renderAvailable manifest)
  KitList JsonOutput -> withRepo JsonOutput $ \repo ->
    loadManifest (repo ^. #dir) `thenE` \manifest -> do
      copies <- installedCopies config
      emit (listDocument (repoAvailability repo) manifest copies)
  KitInstall (Just n) scope -> withRepo HumanOutput $ \repo ->
    loadManifest (repo ^. #dir) `thenE` \manifest ->
      installNamed repo manifest n scope
  -- Without a chooser nothing the refresh could do changes the outcome,
  -- so fail before touching the network.
  KitInstall Nothing scope -> case config ^. #chooseItem of
    Nothing -> pure (Left KitItemNameRequired)
    Just choose -> withRepo HumanOutput $ \repo ->
      loadManifest (repo ^. #dir) `thenE` \manifest -> do
        picked <- choose manifest
        case picked of
          Nothing -> printed "No item chosen; nothing installed."
          Just n -> installNamed repo manifest n scope
  KitUpdate n policy HumanOutput ->
    updateKit config n policy `thenE` (printed . renderUpdateReport)
  KitUpdate n policy JsonOutput ->
    updateKit config n policy `thenE` (emit . updateDocument)
  KitUninstall n scope ->
    uninstallItem config n scope `thenE` (printed . renderUninstallReport n scope)
  KitStatus format -> do
    report <- kitStatus config
    noteUpstream report
    case format of
      HumanOutput -> printed (renderStatusTable (report ^. #rows))
      JsonOutput -> emit (statusDocument report)
  where
    installNamed :: KitRepo -> KitManifest -> Text -> KitScope -> IO (Either KitError ())
    installNamed repo manifest n scope =
      installFrom config (repo ^. #dir) manifest n scope `thenE` \item ->
        printed $
          "Installed " <> itemKind item <> " '" <> itemName item <> "' to " <> scopeLabel scope <> " scope."

    -- List and install need the manifest, so a repository they cannot
    -- reach is an error; a stale cache is a warning and the work goes on.
    -- In JSON mode stdout carries only the document, so the clone notice
    -- goes to stderr with the warnings.
    withRepo :: OutputFormat -> (KitRepo -> IO (Either KitError ())) -> IO (Either KitError ())
    withRepo format next = do
      repo <- ensureKitRepo config
      case repo of
        Left err -> pure (Left err)
        Right resolved -> do
          case resolved ^. #refresh of
            RepoStale err ->
              Text.IO.hPutStrLn stderr $
                "Warning: kit repository could not be refreshed (" <> Text.strip err <> "); using the cached copy."
            RepoCloned ->
              Text.IO.hPutStrLn (noticeHandle format) ("Fetched " <> (config ^. #toolName) <> "-kit.")
            RepoPulled -> pure ()
          next resolved

    noteUpstream :: StatusReport -> IO ()
    noteUpstream report = case report ^. #upstream of
      UpstreamReady -> pure ()
      UpstreamStale err ->
        Text.IO.hPutStrLn stderr $
          "Warning: kit repository could not be refreshed ("
            <> Text.strip err
            <> "); comparing against the cached copy."
      UpstreamUnavailable err ->
        Text.IO.hPutStrLn stderr $
          "Note: kit repository unavailable ("
            <> Text.strip (renderKitError err)
            <> "); showing installed items without upstream comparison."

    thenE :: IO (Either KitError a) -> (a -> IO (Either KitError b)) -> IO (Either KitError b)
    thenE step next = step >>= either (pure . Left) next

    printed :: Text -> IO (Either KitError ())
    printed message = Right <$> Text.IO.putStrLn message

    -- One document, UTF-8 encoded whatever the locale (ADR 0007).
    emit :: Value -> IO (Either KitError ())
    emit document = Right <$> LBS.hPut stdout (Aeson.encode document <> "\n")

    noticeHandle :: OutputFormat -> Handle
    noticeHandle HumanOutput = stdout
    noticeHandle JsonOutput = stderr

    repoAvailability :: KitRepo -> UpstreamAvailability
    repoAvailability repo = case repo ^. #refresh of
      RepoStale err -> UpstreamStale err
      RepoCloned -> UpstreamReady
      RepoPulled -> UpstreamReady

-- | The command adapter: 'runKitCommand', then on 'Left' print
--   @Error: \<renderKitError e\>@ to stderr and exit 1. This is the only
--   function in @baikai-kit@ that exits the process.
runKit :: KitConfig -> KitCommand -> IO ()
runKit config kitCommand = do
  result <- runKitCommand config kitCommand
  case result of
    Right () -> pure ()
    Left err -> do
      Text.IO.hPutStrLn stderr ("Error: " <> renderKitError err)
      exitWith (ExitFailure 1)

renderUpdateReport :: UpdateReport -> Text
renderUpdateReport report =
  Text.intercalate "\n" (headline ++ updatedLines ++ skippedLines ++ [summary] ++ skipSummary)
  where
    headline = case report ^. #refresh of
      Nothing -> []
      Just RepoCloned -> ["Kit repository cloned."]
      Just RepoPulled -> ["Kit repository updated."]
      Just (RepoStale _) -> ["Kit repository updated."]
    updatedLines =
      [ "Updated '" <> n <> "' (" <> scopeLabel scope <> ")"
      | (n, scope) <- report ^. #updated
      ]
    -- A skip is not a failure: the command still exits 0, and the line
    -- says exactly which invocation would overwrite the edits.
    skippedLines =
      [ "Skipped '"
          <> n
          <> "' ("
          <> scopeLabel scope
          <> "): installed files were modified locally; run 'kit update "
          <> n
          <> " --force' to overwrite."
      | (n, scope) <- report ^. #skipped
      ]
    summary = "Updated " <> Text.pack (show (length (report ^. #updated))) <> " item(s)."
    skipSummary
      | null (report ^. #skipped) = []
      | otherwise = ["Skipped " <> Text.pack (show (length (report ^. #skipped))) <> " item(s)."]

installParser :: KitConfig -> Parser KitCommand
installParser config =
  KitInstall
    <$> optional
      ( strArgument
          ( metavar "NAME"
              <> help "Name of the skill or subagent to install; omit it to choose interactively if this tool offers a chooser"
          )
      )
    <*> scopeParser ("Install to project scope (" <> projectDirLabel config <> " under the project root) instead of user scope")

updateParser :: Parser KitCommand
updateParser =
  KitUpdate
    <$> optional (strArgument (metavar "NAME" <> help "Name of a specific item to update (default: all)"))
    <*> flag
      KeepLocalEdits
      OverwriteLocalEdits
      (long "force" <> help "Reinstall items even if their installed files were modified locally")
    <*> formatParser

formatParser :: Parser OutputFormat
formatParser = flag HumanOutput JsonOutput (long "json" <> help "Print one JSON document on stdout")

uninstallParser :: KitConfig -> Parser KitCommand
uninstallParser config =
  KitUninstall
    <$> strArgument (metavar "NAME" <> help "Name of the skill or subagent to uninstall")
    <*> scopeParser ("Uninstall from project scope (" <> projectDirLabel config <> ") instead of user scope")

scopeParser :: String -> Parser KitScope
scopeParser helpText =
  flag UserScope ProjectScope (long "project" <> help helpText)

-- | The tool's project directory as help text shows it, e.g. @.mytool/agents@.
projectDirLabel :: KitConfig -> String
projectDirLabel config = "." <> Text.unpack (config ^. #toolName) <> "/agents"
