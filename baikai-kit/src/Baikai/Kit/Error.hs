-- | Every way a kit operation can fail.
--
--   Library functions return these; only 'Baikai.Kit.Command.runKit'
--   turns one into a process exit. The 'Exception' instance exists for a
--   caller who prefers exceptions and can write @either throwIO pure@.
module Baikai.Kit.Error
  ( KitError (..),
    renderKitError,
  )
where

import Baikai.Prelude
import Control.Exception (Exception)
import Data.Text qualified as Text

-- | A kit operation's failure. Constructors are positional because
--   @-Wpartial-fields@ is on and a record sum would warn.
data KitError
  = -- | The kit checkout holds no @kit.json@.
    KitManifestMissing FilePath
  | -- | The manifest did not decode; the 'Text' is aeson's message.
    KitManifestInvalid FilePath Text
  | -- | The manifest declares a @version@ this installer does not support.
    KitManifestVersionUnsupported FilePath Int
  | -- | No skill or agent of that name is listed.
    KitItemNotFound Text
  | -- | The item lists no source files.
    KitItemHasNoFiles Text
  | -- | An item name failed 'Baikai.Kit.Path.safeItemName'; the second
    --   'Text' is that function's reason.
    KitUnsafeName Text Text
  | -- | A manifest path failed 'Baikai.Kit.Path.safeRelativePath'.
    KitUnsafePath Text Text
  | -- | A listed source file is not there.
    KitSourceMissing FilePath
  | -- | A component of a listed source path is a symbolic link. A kit is
    --   plain files; see 'Baikai.Kit.Path.safeSourcePath'.
    KitSourceSymlink FilePath
  | -- | The canonical source path (first field) is not below the
    --   canonical kit checkout (second field).
    KitSourceEscapes FilePath FilePath
  | -- | Inspecting or reading a source raised an 'IOException'.
    KitSourceUnreadable FilePath Text
  | -- | A first clone failed and no usable cache exists: the repository
    --   URL and git's output.
    KitCloneFailed Text Text
  | -- | @git pull@ failed during @kit update@.
    KitPullFailed Text
  | -- | An install could not be completed: the reason, the destinations
    --   restored by rollback, and the destinations left inconsistent.
    --   Both lists are empty when nothing was changed.
    KitWriteFailed Text [FilePath] [FilePath]
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

-- | The message a command adapter prints. One line, except where a
--   failure needs to say what it left behind.
renderKitError :: KitError -> Text
renderKitError = \case
  KitManifestMissing path ->
    "kit.json not found in kit repository (" <> Text.pack path <> ")."
  KitManifestInvalid path reason ->
    "failed to parse " <> Text.pack path <> ": " <> reason
  -- The supported versions are spelled out rather than read from
  -- 'Baikai.Kit.Manifest.supportedManifestVersions': Manifest imports
  -- this module, so the dependency cannot run the other way.
  KitManifestVersionUnsupported path n ->
    Text.pack path
      <> " declares manifest version "
      <> Text.pack (show n)
      <> "; this installer supports versions 1 and 2."
  KitItemNotFound n -> "'" <> n <> "' not found in kit manifest."
  KitItemHasNoFiles n -> "'" <> n <> "' lists no source files."
  KitUnsafeName raw reason -> "unsafe item name '" <> raw <> "': " <> reason
  KitUnsafePath raw reason -> "unsafe manifest path '" <> raw <> "': " <> reason
  KitSourceMissing path -> "source file does not exist: " <> Text.pack path
  KitSourceSymlink path -> "refusing symbolic link in kit source: " <> Text.pack path
  KitSourceEscapes path root ->
    "kit source resolves outside the kit checkout: "
      <> Text.pack path
      <> " (checkout: "
      <> Text.pack root
      <> ")"
  KitSourceUnreadable path reason ->
    "cannot inspect kit source " <> Text.pack path <> ": " <> reason
  KitCloneFailed url output ->
    "failed to fetch kit repository " <> url <> ": " <> output
  KitPullFailed output ->
    "failed to update kit repository: "
      <> output
      <> "\nThe cached copy is unchanged; installed items were not reinstalled."
  KitWriteFailed reason restored leftInconsistent ->
    Text.intercalate "\n" ("install failed: " <> reason : aftermath)
    where
      aftermath
        | null restored && null leftInconsistent = ["No changes were made."]
        | otherwise =
            ["Restored: " <> renderPaths restored | not (null restored)]
              <> [ "Left inconsistent (repair by reinstalling): " <> renderPaths leftInconsistent
                 | not (null leftInconsistent)
                 ]
      renderPaths = Text.intercalate ", " . map Text.pack
