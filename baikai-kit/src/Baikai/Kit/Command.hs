module Baikai.Kit.Command
  ( KitCommand (..),
    kitCommandParser,
    runKit,
  )
where

import Baikai.Kit.Config (KitConfig, KitScope (..))
import Baikai.Kit.Install (installItem, listAvailable, uninstallItem, updateKit)
import Baikai.Kit.Status (kitStatus)
import Baikai.Prelude
import Options.Applicative

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

runKit :: KitConfig -> KitCommand -> IO ()
runKit config = \case
  KitList -> listAvailable config
  KitInstall n scope -> installItem config n scope
  KitUpdate n -> updateKit config n
  KitUninstall n scope -> uninstallItem config n scope
  KitStatus -> kitStatus config

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
