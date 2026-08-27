-- | The optparse-applicative adapter a consuming tool wires up as its
--   @kit@ subcommand.
--
--   'runKit' is the only function in @baikai-kit@ that exits the process;
--   see @docs/adr/0013-library-code-never-calls-exitfailure.md@.
module Baikai.Kit.Command
  ( KitCommand (..),
    kitCommandParser,
    runKit,
    runKitCommand,
  )
where

import Baikai.Kit.Config (KitConfig, KitScope (..), scopeLabel)
import Baikai.Kit.Error (KitError, renderKitError)
import Baikai.Kit.Install
  ( UpdateReport,
    installFrom,
    loadManifest,
    renderAvailable,
    renderUninstallReport,
    uninstallItem,
    updateKit,
  )
import Baikai.Kit.Manifest (itemKind, itemName)
import Baikai.Kit.Repo (KitRepo, RepoRefresh (..), ensureKitRepo)
import Baikai.Kit.Status (StatusReport, UpstreamAvailability (..), kitStatus, renderStatusTable)
import Baikai.Prelude
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Options.Applicative
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (stderr)

data KitCommand
  = KitList
  | KitInstall !Text !KitScope
  | KitUpdate !(Maybe Text)
  | KitUninstall !Text !KitScope
  | KitStatus
  deriving stock (Show)

kitCommandParser :: Parser KitCommand
kitCommandParser =
  hsubparser
    ( command "list" (info (pure KitList) (progDesc "List available skills and subagents"))
        <> command "install" (info installParser (progDesc "Install a skill or subagent"))
        <> command "update" (info updateParser (progDesc "Update installed skills and subagents"))
        <> command "uninstall" (info uninstallParser (progDesc "Uninstall a skill or subagent"))
        <> command "status" (info (pure KitStatus) (progDesc "Show installed skills and subagents"))
    )
    <|> pure KitList

-- | Run one verb and print its normal output. Never exits, so a consumer
--   that wants its own exit codes can map the 'KitError' itself.
runKitCommand :: KitConfig -> KitCommand -> IO (Either KitError ())
runKitCommand config = \case
  KitList -> withRepo $ \repo ->
    loadManifest (repo ^. #dir) `thenE` \manifest ->
      printed (renderAvailable manifest)
  KitInstall n scope -> withRepo $ \repo ->
    loadManifest (repo ^. #dir) `thenE` \manifest ->
      installFrom config (repo ^. #dir) manifest n scope `thenE` \item ->
        printed $
          "Installed " <> itemKind item <> " '" <> itemName item <> "' to " <> scopeLabel scope <> " scope."
  KitUpdate n ->
    updateKit config n `thenE` (printed . renderUpdateReport)
  KitUninstall n scope ->
    uninstallItem config n scope `thenE` (printed . renderUninstallReport n scope)
  KitStatus -> do
    report <- kitStatus config
    noteUpstream report
    Text.IO.putStrLn (renderStatusTable (report ^. #rows))
    pure (Right ())
  where
    -- List and install need the manifest, so a repository they cannot
    -- reach is an error; a stale cache is a warning and the work goes on.
    withRepo :: (KitRepo -> IO (Either KitError ())) -> IO (Either KitError ())
    withRepo next = do
      repo <- ensureKitRepo config
      case repo of
        Left err -> pure (Left err)
        Right resolved -> do
          case resolved ^. #refresh of
            RepoStale err ->
              Text.IO.hPutStrLn stderr $
                "Warning: kit repository could not be refreshed (" <> Text.strip err <> "); using the cached copy."
            RepoCloned -> Text.IO.putStrLn ("Fetched " <> (config ^. #toolName) <> "-kit.")
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
  Text.intercalate "\n" (headline : updatedLines ++ [summary])
  where
    headline = case report ^. #refresh of
      RepoCloned -> "Kit repository cloned."
      RepoPulled -> "Kit repository updated."
      RepoStale _ -> "Kit repository updated."
    updatedLines =
      [ "Updated '" <> n <> "' (" <> scopeLabel scope <> ")"
      | (n, scope) <- report ^. #updated
      ]
    summary = "Updated " <> Text.pack (show (length (report ^. #updated))) <> " item(s)."

installParser :: Parser KitCommand
installParser =
  KitInstall
    <$> strArgument (metavar "NAME" <> help "Name of the skill or subagent to install")
    <*> scopeParser "Install to project scope instead of user scope"

updateParser :: Parser KitCommand
updateParser =
  KitUpdate
    <$> optional (strArgument (metavar "NAME" <> help "Name of a specific item to update (default: all)"))

uninstallParser :: Parser KitCommand
uninstallParser =
  KitUninstall
    <$> strArgument (metavar "NAME" <> help "Name of the skill or subagent to uninstall")
    <*> scopeParser "Uninstall from project scope instead of user scope"

scopeParser :: String -> Parser KitScope
scopeParser helpText =
  flag UserScope ProjectScope (long "project" <> help helpText)
