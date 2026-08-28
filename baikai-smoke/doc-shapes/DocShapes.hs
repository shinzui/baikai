-- | Checks that every @## Shape@ block in @docs\/capabilities\/@ still says
-- what the code says.
--
-- Compiling this suite proves every fenced @haskell@ block type-checks
-- against the current exports, because each block is also the marked
-- region of a @Shape.CapN@ module. Running it proves the two copies have
-- not drifted apart: the record's block is compared line by line with
-- the region between @-- BEGIN CAP-N@ and @-- END CAP-N@ in its module.
--
-- The block a record shows is what a consumer copies, so it is written
-- without fixture noise: free names such as @model@, @ctx@ and @opts@
-- come from "Shape.Fixtures", and each preamble @import@ line in the
-- record must appear verbatim in the module, which may import more.
--
-- CAP-18's Shape is @kdl@, not Haskell. Configuration is data, so the
-- honest equivalent of compiling it is resolving it: the block is
-- written to a temporary file and read back through
-- "Baikai.Agent.Config".
module Main (main) where

import Baikai.Agent.Config
  ( AgentConfigPaths (repoConfig, repositoryRoot),
    AgentJobEntry (name),
    emptyAgentConfigPaths,
    listAgentJobs,
    renderAgentConfigError,
    resolveAgentJob,
  )
import Control.Monad (forM)
import Data.Char (isSpace)
import Data.List (dropWhileEnd, isPrefixOf, isSuffixOf, sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Settei.Env (envSnapshot)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getCurrentDirectory,
    getTemporaryDirectory,
    listDirectory,
    removeDirectoryRecursive,
  )
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (takeBaseName, takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

-- | Where the checker looks and what it reports.
capabilitiesDir :: FilePath
capabilitiesDir = "docs" </> "capabilities"

shapeModulesDir :: FilePath
shapeModulesDir = "baikai-smoke" </> "doc-shapes" </> "Shape"

-- | One record, as the checker reads it off disk.
data Record = Record
  { recordId :: !Text,
    file :: !FilePath,
    block :: !(Maybe Fence)
  }

-- | A fenced block under @## Shape@: its language tag and its lines.
data Fence = Fence
  { language :: !Text,
    body :: ![Text]
  }

-- | What checking one record produced.
data Outcome
  = Agrees !Text !FilePath !FilePath
  | Resolves !Text !FilePath !Text
  | Skipped !Text !FilePath !Text
  | Differs !Text !FilePath !FilePath !Mismatch

-- | Why a record and its module disagree.
data Mismatch
  = MissingModule
  | MissingMarkers
  | MissingImport !Text
  | LineDiffers !Int !Text !Text
  | LengthDiffers !Int !Int
  | KdlFailed !Text

main :: IO ()
main = do
  root <- findRepoRoot
  records <- readRecords root
  outcomes <- forM records (checkRecord root)
  moduleProblems <- checkModuleSet root records
  mapM_ (putStrLn . renderOutcome) outcomes
  mapM_ (hPutStrLn stderr) moduleProblems
  let differing = [o | o@Differs {} <- outcomes]
      agreeing = length [() | Agrees {} <- outcomes]
      resolving = length [() | Resolves {} <- outcomes]
      skipping = length [() | Skipped {} <- outcomes]
  if null differing && null moduleProblems
    then do
      putStrLn
        ( "doc-shapes: "
            <> show agreeing
            <> " haskell blocks agree, "
            <> show resolving
            <> " kdl block resolves, "
            <> show skipping
            <> " skipped"
        )
      exitSuccess
    else do
      putStrLn ("doc-shapes: " <> show (length differing) <> " block(s) differ")
      exitFailure

-- | Walk up from the working directory to the directory holding
-- @cabal.project@, the trick @baikai\/gen\/GenModels.hs@ uses.
findRepoRoot :: IO FilePath
findRepoRoot = getCurrentDirectory >>= go
  where
    go dir = do
      here <- doesFileExist (dir </> "cabal.project")
      if here
        then pure dir
        else
          let up = takeDirectory dir
           in if up == dir
                then fail "doc-shapes: no cabal.project above the working directory"
                else go up

-- | Every concept in the bundle. @index.md@ and @log.md@ are reserved
-- files, not concepts.
readRecords :: FilePath -> IO [Record]
readRecords root = do
  let dir = root </> capabilitiesDir
  entries <- listDirectory dir
  let names =
        sort
          [ n
          | n <- entries,
            ".md" `isSuffixOf` n,
            n /= "index.md",
            n /= "log.md"
          ]
  forM names $ \n -> do
    text <- TextIO.readFile (dir </> n)
    let ls = Text.lines text
    pure
      Record
        { recordId = capabilityIdOf ls,
          -- Repository-relative, so a drift report can be pasted into a
          -- commit message or an issue and still name a file.
          file = capabilitiesDir </> n,
          block = shapeBlock ls
        }

-- | The @capabilityId:@ frontmatter value.
capabilityIdOf :: [Text] -> Text
capabilityIdOf ls =
  case mapMaybe (Text.stripPrefix "capabilityId:") ls of
    value : _ -> Text.strip (Text.dropWhile (== '"') (Text.strip value))
    [] -> "CAP-?"

-- | The first fenced block under @## Shape@, preferring a @haskell@
-- fence: a record may show a @console@ transcript alongside the code a
-- consumer copies.
shapeBlock :: [Text] -> Maybe Fence
shapeBlock ls = case dropWhile (not . isShapeHeading) ls of
  [] -> Nothing
  _ : rest ->
    let section = takeWhile (not . isOtherHeading) rest
        fences = collectFences section
     in case [f | f <- fences, language f == "haskell"] of
          f : _ -> Just f
          [] -> case fences of
            f : _ -> Just f
            [] -> Nothing
  where
    isShapeHeading l = Text.strip l == "## Shape"
    isOtherHeading l = "## " `Text.isPrefixOf` l

-- | Every fence in a section, in order.
collectFences :: [Text] -> [Fence]
collectFences [] = []
collectFences (l : rest)
  | Just tag <- Text.stripPrefix "```" (Text.strip l),
    not (Text.null tag) =
      let (inside, after) = break isClosing rest
       in Fence {language = Text.strip tag, body = inside} : collectFences (drop 1 after)
  | otherwise = collectFences rest
  where
    isClosing l' = Text.strip l' == "```"

-- | Check one record against its module.
checkRecord :: FilePath -> Record -> IO Outcome
checkRecord root Record {recordId = rid, file = f, block = mBlock} =
  case mBlock of
    Nothing -> pure (Skipped rid f "no Shape block")
    Just Fence {language = "haskell", body = ls} -> checkHaskell root rid f ls
    Just Fence {language = "kdl", body = ls} -> checkKdl rid f ls
    Just Fence {language = lang} ->
      pure (Skipped rid f ("no haskell Shape (" <> lang <> ")"))

-- | Compare a @haskell@ block with the marked region of its module.
checkHaskell :: FilePath -> Text -> FilePath -> [Text] -> IO Outcome
checkHaskell root rid f ls = do
  let modulePath = root </> shapeModulesDir </> moduleFileName rid
      shown = shapeModulesDir </> moduleFileName rid
  present <- doesFileExist modulePath
  if not present
    then pure (Differs rid f shown MissingModule)
    else do
      moduleText <- TextIO.readFile modulePath
      let moduleLines = Text.lines moduleText
          (preamble, blockBody) = splitPreamble ls
      case moduleRegion rid moduleLines of
        Nothing -> pure (Differs rid f shown MissingMarkers)
        Just region -> case missingImport moduleLines preamble of
          Just imp -> pure (Differs rid f shown (MissingImport imp))
          Nothing -> case compareLines (trimBlankEdges blockBody) region of
            Just mismatch -> pure (Differs rid f shown mismatch)
            Nothing -> pure (Agrees rid f shown)

-- | @CAP-4@ becomes @Cap4.hs@.
moduleFileName :: Text -> FilePath
moduleFileName rid = "Cap" <> Text.unpack (Text.drop 4 rid) <> ".hs"

-- | Split a block at its first blank line into a preamble of @import@
-- lines and a body. A block whose leading lines are not all imports is
-- all body.
splitPreamble :: [Text] -> ([Text], [Text])
splitPreamble ls = case break Text.null ls of
  (before, _ : after)
    | not (null before),
      all ("import " `Text.isPrefixOf`) before ->
        (before, after)
  _ -> ([], ls)

-- | The lines strictly between the markers, with a uniform two-space
-- indent removed when every non-blank line carries one.
--
-- Blank lines at either edge are dropped: the formatter puts one before
-- the closing marker, which is layout rather than content.
moduleRegion :: Text -> [Text] -> Maybe [Text]
moduleRegion rid ls =
  case break (isMarker "BEGIN") ls of
    (_, []) -> Nothing
    (_, _ : rest) -> case break (isMarker "END") rest of
      (_, []) -> Nothing
      (inside, _ : _) -> Just (trimBlankEdges (stripIndent inside))
  where
    isMarker which l = Text.strip l == "-- " <> which <> " " <> rid

-- | Drop blank lines from both ends of a block.
trimBlankEdges :: [Text] -> [Text]
trimBlankEdges =
  dropWhileEnd blank . dropWhile blank
  where
    blank = Text.null . Text.strip

-- | Remove one uniform two-space indent, when there is one.
stripIndent :: [Text] -> [Text]
stripIndent ls
  | all indented ls = map (Text.drop 2) ls
  | otherwise = ls
  where
    indented l = Text.null (Text.strip l) || "  " `Text.isPrefixOf` l

-- | The first preamble import the module does not have at column zero.
missingImport :: [Text] -> [Text] -> Maybe Text
missingImport moduleLines = go
  where
    go [] = Nothing
    go (imp : rest)
      | any (== imp) moduleLines = go rest
      | otherwise = Just imp

-- | The first line on which the record and the module disagree.
compareLines :: [Text] -> [Text] -> Maybe Mismatch
compareLines recordLines moduleLines
  | length recordLines /= length moduleLines =
      case firstDiffering of
        Just m -> Just m
        Nothing -> Just (LengthDiffers (length recordLines) (length moduleLines))
  | otherwise = firstDiffering
  where
    firstDiffering =
      case [ (n, a, b)
           | (n, a, b) <- zip3 [1 :: Int ..] recordLines moduleLines,
             stripTrailing a /= stripTrailing b
           ] of
        (n, a, b) : _ -> Just (LineDiffers n a b)
        [] -> Nothing
    stripTrailing = Text.dropWhileEnd isSpace

-- | Resolve CAP-18's @kdl@ block the way @baikai agent@ does.
checkKdl :: Text -> FilePath -> [Text] -> IO Outcome
checkKdl rid f ls = do
  tmpRoot <- getTemporaryDirectory
  let dir = tmpRoot </> "baikai-doc-shapes"
      path = dir </> "agents.kdl"
  createDirectoryIfMissing True dir
  TextIO.writeFile path (Text.unlines ls)
  let paths =
        emptyAgentConfigPaths
          { repoConfig = Just path,
            repositoryRoot = dir
          }
  listed <- listAgentJobs paths
  resolved <- resolveAgentJob paths (envSnapshot []) [] "review"
  removeDirectoryRecursive dir
  pure $ case (listed, resolved) of
    (Left err, _) -> failing (renderAgentConfigError err)
    (_, Left err) -> failing (renderAgentConfigError err)
    (Right entries, Right _)
      | map name entries == ["review"] ->
          Resolves rid f "jobs [review]"
      | otherwise ->
          failing
            ( "declares jobs "
                <> Text.intercalate ", " (map name entries)
                <> ", expected review"
            )
  where
    failing why = Differs rid f "the kdl resolver" (KdlFailed why)

-- | Every module on disk must belong to a record with a @haskell@
-- block, and every such record must have a module.
checkModuleSet :: FilePath -> [Record] -> IO [String]
checkModuleSet root records = do
  entries <- listDirectory (root </> shapeModulesDir)
  let modules =
        sort
          [ takeBaseName n
          | n <- entries,
            ".hs" `isSuffixOf` n,
            "Cap" `isPrefixOf` n
          ]
      expected =
        sort
          [ "Cap" <> Text.unpack (Text.drop 4 (recordId r))
          | r <- records,
            Just Fence {language = "haskell"} <- [block r]
          ]
      orphans = [m | m <- modules, m `notElem` expected]
      missing = [m | m <- expected, m `notElem` modules]
  pure
    ( [ "doc-shapes: " <> m <> ".hs has no record with a haskell Shape block"
      | m <- orphans
      ]
        <> [ "doc-shapes: no module for a record with a haskell Shape block: "
               <> m
               <> ".hs"
           | m <- missing
           ]
    )

-- | One line per record.
renderOutcome :: Outcome -> String
renderOutcome = \case
  Agrees rid f shown ->
    pad (Text.unpack rid) <> pad f <> "agrees with " <> shown
  Resolves rid f what ->
    pad (Text.unpack rid) <> pad f <> "kdl Shape resolves: " <> Text.unpack what
  Skipped rid f why ->
    pad (Text.unpack rid) <> pad f <> Text.unpack why <> "; skipped"
  Differs rid f shown mismatch ->
    pad (Text.unpack rid)
      <> pad f
      <> "DIFFERS from "
      <> shown
      <> "\n"
      <> renderMismatch mismatch
  where
    pad s = s <> replicate (max 1 (width - length s)) ' '
    width = 48

-- | What to change, on which side.
renderMismatch :: Mismatch -> String
renderMismatch = \case
  MissingModule -> "  the module does not exist"
  MissingMarkers -> "  the module has no -- BEGIN/-- END marker pair for this record"
  MissingImport imp -> "  " <> Text.unpack imp
  LengthDiffers r m ->
    "  record has " <> show r <> " body lines; module region has " <> show m
  KdlFailed why -> "  " <> Text.unpack why
  LineDiffers n a b ->
    "  record line "
      <> show n
      <> ": "
      <> Text.unpack a
      <> "\n  module line "
      <> show n
      <> ": "
      <> Text.unpack b
