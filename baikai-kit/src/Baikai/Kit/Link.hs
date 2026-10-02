-- | Shared Claude names are aliases to tool-owned copies, never copies.
module Baikai.Kit.Link
  ( SharedLink (..),
    claudeLinks,
    linkIsOurs,
    preflightLink,
    applyLink,
    removeLink,
    foreignOwner,
    pathExists,
    relativeLinkTarget,
  )
where

import Baikai.AgentAssets (agentTargetPath, skillTargetPath)
import Baikai.Interactive (InteractiveProvider (InteractiveClaude), InteractiveScope (InteractiveProjectScope))
import Baikai.Kit.Config (KitConfig, KitScope (..), providerAgentsBase, sharedClaudeBase)
import Baikai.Kit.Error (KitError (..))
import Baikai.Kit.Manifest (KitItemKind (..))
import Baikai.Prelude
import Control.Exception (IOException, throwIO, try)
import Control.Monad (unless, when)
import Data.List (find, isPrefixOf, isSuffixOf)
import Data.Text qualified as Text
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    createDirectoryLink,
    createFileLink,
    doesDirectoryExist,
    doesPathExist,
    getSymbolicLinkTarget,
    listDirectory,
    makeAbsolute,
    pathIsSymbolicLink,
    removeFile,
  )
import System.FilePath (joinPath, splitDirectories, takeDirectory, (</>))

data SharedLink = SharedLink
  { location :: !FilePath,
    target :: !FilePath,
    directory :: !Bool,
    relative :: !Bool
  }
  deriving stock (Generic, Show)

claudeLinks :: KitConfig -> KitScope -> KitItemKind -> Text -> Bool -> IO [SharedLink]
claudeLinks config scope kind n resources = do
  shared <- sharedClaudeBase config scope >>= makeAbsolute
  owned <- providerAgentsBase config InteractiveClaude scope >>= makeAbsolute
  let name = Text.unpack n
      path = case kind of
        SkillKind -> skillTargetPath InteractiveClaude InteractiveProjectScope name
        AgentKind -> agentTargetPath InteractiveClaude InteractiveProjectScope name
      paths =
        (path, kind == SkillKind)
          : [(takeDirectory path </> name, True) | kind == AgentKind, resources]
  pure [SharedLink (shared </> p) (owned </> p) isDir (scope == ProjectScope) | (p, isDir) <- paths]

pathExists :: FilePath -> IO Bool
pathExists path = do
  exists <- doesPathExist path
  linked <- either (const False) id <$> try @IOException (pathIsSymbolicLink path)
  pure (exists || linked)

linkIsOurs :: SharedLink -> IO Bool
linkIsOurs link = do
  linked <- either (const False) id <$> try @IOException (pathIsSymbolicLink (link ^. #location))
  if not linked
    then pure False
    else do
      raw <- getSymbolicLinkTarget (link ^. #location)
      actual <- canonicalizePath (takeDirectory (link ^. #location) </> raw)
      expected <- canonicalizePath (link ^. #target)
      pure (actual == expected)

preflightLink :: SharedLink -> IO ()
preflightLink link = do
  exists <- pathExists (link ^. #location)
  ours <- linkIsOurs link
  when (exists && not ours) $ do
    owner <- foreignOwner (link ^. #location)
    throwIO (KitSharedNameTaken (link ^. #location) owner)

applyLink :: SharedLink -> IO ()
applyLink link = do
  preflightLink link
  ours <- linkIsOurs link
  unless ours $ do
    createDirectoryIfMissing True (takeDirectory (link ^. #location))
    let target =
          if link ^. #relative
            then relativeLinkTarget (takeDirectory (link ^. #location)) (link ^. #target)
            else link ^. #target
    (if link ^. #directory then createDirectoryLink else createFileLink) target (link ^. #location)

removeLink :: SharedLink -> IO Bool
removeLink link = do
  ours <- linkIsOurs link
  when ours (removeFile (link ^. #location))
  pure ours

-- | A lexical relative target, including sibling directories.
relativeLinkTarget :: FilePath -> FilePath -> FilePath
relativeLinkTarget parent target = go (splitDirectories parent) (splitDirectories target)
  where
    go (a : as) (b : bs) | a == b = go as bs
    go as bs = joinPath (replicate (length as) ".." ++ bs)

foreignOwner :: FilePath -> IO (Maybe Text)
foreignOwner path = do
  linked <- either (const False) id <$> try @IOException (pathIsSymbolicLink path)
  if linked
    then do
      raw <- getSymbolicLinkTarget path
      absolute <- canonicalizePath (takeDirectory path </> raw)
      pure (ownerOf (splitDirectories absolute))
    else do
      isDir <- doesDirectoryExist path
      files <- if isDir then listDirectory path else pure []
      pure $ Text.pack . drop 1 . takeWhileSuffix <$> find sidecar files
  where
    sidecar f = "." `isPrefixOf` f && "-kit.json" `isSuffixOf` f
    takeWhileSuffix f = take (length f - length ("-kit.json" :: String)) f
    ownerOf (".config" : tool : "agents" : _) = Just (Text.pack tool)
    ownerOf (tool : "agents" : _) | "." `isPrefixOf` tool = Just (Text.pack (drop 1 tool))
    ownerOf (_ : rest) = ownerOf rest
    ownerOf [] = Nothing
