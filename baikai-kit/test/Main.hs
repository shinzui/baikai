{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Baikai.Interactive (InteractiveProvider (InteractiveClaude, InteractiveCodex))
import Baikai.Kit
  ( AgentEntry (..),
    KitCommand (..),
    KitCondition (..),
    KitConfig (..),
    KitError (..),
    KitItem (..),
    KitItemKind (..),
    KitManifest (..),
    KitScope (..),
    OverwritePolicy (..),
    PlannedWrite (..),
    PullResult (..),
    RemovalOutcome (..),
    SidecarMeta (..),
    SkillEntry (..),
    UpstreamAvailability (..),
    WriteContent (..),
    agentDirsForSession,
    classify,
    collectStatus,
    computeKitHash,
    conditionLabel,
    executePlanWith,
    findProjectRoot,
    installItem,
    kitCommandParser,
    kitConfig,
    kitStatus,
    loadManifest,
    projectRootByMarkers,
    pullKitRepo,
    readSidecar,
    reinstallPresent,
    renderConditions,
    renderUninstallReport,
    runKit,
    runKitCommand,
    safeItemName,
    safeRelativePath,
    safeSourcePath,
    sidecarFileName,
    sidecarPath,
    stripYamlFrontmatter,
    uninstallItem,
    updateKit,
  )
import Baikai.Prelude
import Control.Exception (finally, try)
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find, isInfixOf, isSuffixOf, nub, sort)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Options.Applicative
  ( ParserResult (..),
    defaultPrefs,
    execParserPure,
    getParseResult,
    helper,
    info,
    renderFailure,
    (<**>),
  )
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    createDirectoryLink,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    getCurrentDirectory,
    listDirectory,
    removeDirectoryRecursive,
    removeFile,
    renameFile,
    withCurrentDirectory,
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, localOption, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Runners (NumThreads (NumThreads))

main :: IO ()
main =
  defaultMain $
    localOption (NumThreads 1) $
      testGroup
        "baikai-kit"
        [ manifestTests,
          hashTests,
          pathSafetyTests,
          symlinkSafetyTests,
          frontmatterTests,
          classifyTests,
          statusFilesystemTests,
          installRoundTripTests,
          typedErrorTests,
          installFidelityTests,
          projectRootTests,
          commandTests
        ]

manifestTests :: TestTree
manifestTests =
  testGroup
    "Manifest backward compatibility"
    [ fixtureCase "mori-kit.json" 2 4 0,
      fixtureCase "rei-kit.json" 1 9 1,
      fixtureCase "seihou-kit.json" 1 2 0
    ]

fixtureCase :: FilePath -> Int -> Int -> Int -> TestTree
fixtureCase file expectedVersion expectedSkills expectedAgents =
  testCase (file <> " decodes") $ do
    manifest <- decodeFixture file
    (manifest ^. #version) @?= expectedVersion
    length (manifest ^. #skills) @?= expectedSkills
    length (manifest ^. #agents) @?= expectedAgents

hashTests :: TestTree
hashTests =
  testGroup
    "Hash"
    [ testCase "computeKitHash is deterministic regardless of input order" $
        withSystemTempDirectory "baikai-kit-hash" $ \dir -> do
          BS.writeFile (dir </> "a.md") "alpha"
          BS.writeFile (dir </> "b.md") "beta"
          BS.writeFile (dir </> "c.md") "gamma"
          h1 <- assertRight =<< computeKitHash dir "." ["a.md", "b.md", "c.md"]
          h2 <- assertRight =<< computeKitHash dir "." ["c.md", "a.md", "b.md"]
          h1 @?= h2
          assertBool "hash should carry sha256 prefix" ("sha256:" `Text.isPrefixOf` h1),
      testCase "computeKitHash changes when file content changes" $
        withSystemTempDirectory "baikai-kit-hash-mut" $ \dir -> do
          BS.writeFile (dir </> "a.md") "alpha"
          before <- assertRight =<< computeKitHash dir "." ["a.md"]
          BS.writeFile (dir </> "a.md") "alpha-modified"
          after <- assertRight =<< computeKitHash dir "." ["a.md"]
          assertBool "hashes must differ after content change" (before /= after)
    ]

classifyTests :: TestTree
classifyTests =
  testGroup
    "Status.classify"
    [ testCase "no sidecar => unknown" $
        classify Nothing (Just (mkSkillItem "foo" (Just "1.0"))) (Just "h") @?= [KitUnknown],
      testCase "no upstream entry with a sidecar => delisted" $
        classify (Just (mkSidecar (Just "1.0") "h")) Nothing (Just "h") @?= [KitDelisted],
      testCase "version mismatch => outdated" $
        classify
          (Just (mkSidecar (Just "1.0") "h"))
          (Just (mkSkillItem "foo" (Just "2.0")))
          (Just "h")
          @?= [KitOutdated],
      testCase "version and hash mismatch => outdated+changed-upstream" $
        classify
          (Just (mkSidecar (Just "1.0") "h1"))
          (Just (mkSkillItem "foo" (Just "2.0")))
          (Just "h2")
          @?= [KitOutdated, KitChangedUpstream],
      testCase "hash mismatch => changed-upstream" $
        classify
          (Just (mkSidecar (Just "1.0") "h1"))
          (Just (mkSkillItem "foo" (Just "1.0")))
          (Just "h2")
          @?= [KitChangedUpstream],
      testCase "version and hash match => up-to-date" $
        classify
          (Just (mkSidecar (Just "1.0") "h"))
          (Just (mkSkillItem "foo" (Just "1.0")))
          (Just "h")
          @?= [],
      testCase "no upstream hash on matching version => up-to-date" $
        classify
          (Just (mkSidecar (Just "1.0") "h"))
          (Just (mkAgentItem "foo" (Just "1.0")))
          Nothing
          @?= [],
      testCase "renderConditions joins labels in order" $ do
        renderConditions [] @?= "up-to-date"
        renderConditions [KitOutdated, KitChangedUpstream, KitLocallyModified] @?= "outdated+changed-upstream+modified"
    ]

pathSafetyTests :: TestTree
pathSafetyTests =
  testGroup
    "Path safety"
    [ testCase "safeRelativePath accepts and normalises harmless paths" $ do
        safeRelativePath "SKILL.md" @?= Right "SKILL.md"
        safeRelativePath "skills/review" @?= Right "skills/review"
        safeRelativePath "a/./b" @?= Right ("a" </> "b"),
      testCase "safeRelativePath rejects zip-slip, absolute paths, backslashes, and NUL" $ do
        mapM_
          (assertLeft . safeRelativePath)
          ["", "/etc/passwd", "../x", "a/../../x", "..", "a/..", "a\\..\\b", "a\0b"],
      testCase "safeItemName rejects multi-component and hidden names" $ do
        safeItemName "reviewer" @?= Right "reviewer"
        mapM_ (assertLeft . safeItemName) ["a/b", ".", ".hidden"],
      testCase "install refuses a manifest file path that escapes the install root" $
        withPreparedKitHome $ \home cache -> do
          BS.writeFile (cache </> "kit.json") maliciousManifestJson
          result <- installItem testConfig "evil" UserScope
          assertKitError "KitUnsafePath" isUnsafePath result
          assertFileMissing (takeDirectory home </> "escape.txt")
          exitResult <- try @ExitCode (runKit testConfig (KitInstall (Just "evil") UserScope))
          exitResult @?= Left (ExitFailure 1),
      testCase "uninstall refuses a traversal name" $
        withPreparedKitHome $ \home _cache -> do
          let victim = home </> "victim"
          createDirectoryIfMissing True victim
          result <- uninstallItem testConfig "../victim" UserScope
          assertKitError "KitUnsafeName" isUnsafeName result
          assertDirectoryExists victim
          exitResult <- try @ExitCode (runKit testConfig (KitUninstall "../victim" UserScope))
          exitResult @?= Left (ExitFailure 1)
          assertDirectoryExists victim
    ]

symlinkSafetyTests :: TestTree
symlinkSafetyTests =
  testGroup
    "Symlink safety"
    [ testCase "safeSourcePath refuses a symlinked component" $
        withPreparedKitHome $ \home cache -> do
          plantSymlinkedSource home cache
          refused <- safeSourcePath cache ("skills" </> "demo" </> "sub" </> "secret.txt")
          refused @?= Left (KitSourceSymlink (cache </> "skills" </> "demo" </> "sub"))
          absolute <- safeSourcePath cache "/etc/passwd"
          case absolute of
            Left (KitUnsafePath _ _) -> pure ()
            other -> assertFailure ("expected KitUnsafePath, got " <> show other)
          plain <- safeSourcePath cache ("skills" </> "demo" </> "SKILL.md")
          plain @?= Right (cache </> "skills" </> "demo" </> "SKILL.md"),
      testCase "computeKitHash refuses a symlinked source" $
        withPreparedKitHome $ \home cache -> do
          plantSymlinkedSource home cache
          hashed <- computeKitHash cache ("skills" </> "demo") ["SKILL.md", "sub" </> "secret.txt"]
          hashed @?= Left (KitSourceSymlink (cache </> "skills" </> "demo" </> "sub")),
      testCase "install refuses a symlinked source and writes nothing" $
        withPreparedKitHome $ \home cache -> do
          plantSymlinkedSource home cache
          let claudeSkill = home </> ".config" </> "testkit" </> "agents" </> ".claude" </> "skills" </> "demo"
          result <- installItem testConfig "demo" UserScope
          assertKitError "KitSourceSymlink" isSourceSymlink result
          assertFileMissing (claudeSkill </> "sub" </> "secret.txt")
          assertFileMissing (claudeSkill </> "SKILL.md"),
      testCase "status reports refused when upstream lists a symlinked source" $
        withPreparedKitHome $ \home cache -> do
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          plantSymlinkedSource home cache
          rows <- collectStatus testConfig cache [(UserScope, "user")]
          let demoRows = filter ((== "demo") . view #name) rows
          assertBool "expected demo status rows" (not (null demoRows))
          mapM_ (\row -> row ^. #conditions @?= [KitUpstreamRefused]) demoRows,
      testCase "conditionLabel names the refused condition" $
        conditionLabel KitUpstreamRefused @?= "refused"
    ]

frontmatterTests :: TestTree
frontmatterTests =
  testGroup
    "Frontmatter"
    [ testCase "stripYamlFrontmatter handles LF, CRLF, and final delimiter without newline" $ do
        stripYamlFrontmatter "---\nname: x\n---\nBody.\n" @?= "Body.\n"
        stripYamlFrontmatter "---\r\nname: x\r\n---\r\nBody.\r\n" @?= "Body.\n"
        stripYamlFrontmatter "---\nname: x\n---" @?= "",
      testCase "stripYamlFrontmatter leaves non-frontmatter and unterminated blocks unchanged" $ do
        stripYamlFrontmatter "Body.\n" @?= "Body.\n"
        stripYamlFrontmatter "---\nname: x\nBody.\n" @?= "---\nname: x\nBody.\n",
      testCase "stripYamlFrontmatter normalises line endings on every branch" $ do
        stripYamlFrontmatter "Body.\r\n" @?= "Body.\n"
        stripYamlFrontmatter "---\r\nname: x\r\nBody.\r\n" @?= "---\nname: x\nBody.\n"
    ]

statusFilesystemTests :: TestTree
statusFilesystemTests =
  testGroup
    "Status filesystem"
    [ testCase "sidecarPath drops any agent target extension" $
        withPreparedKitHome $ \home _cache -> do
          let claudeBase = home </> ".config" </> "testkit" </> "agents"
              codexBase = home
              sidecar = sidecarFileName testConfig
          sidecarPath InteractiveClaude AgentKind "reviewer" claudeBase sidecar
            @?= claudeBase </> ".claude" </> "agents" </> "reviewer.testkit-kit.json"
          sidecarPath InteractiveCodex AgentKind "reviewer" codexBase sidecar
            @?= codexBase </> ".codex" </> "agents" </> "reviewer.testkit-kit.json",
      testCase "delisted installed item keeps sidecar version in status" $
        withPreparedKitHome $ \_home cache -> do
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          BS.writeFile (cache </> "kit.json") manifestWithoutDemoJson
          rows <- collectStatus testConfig cache [(UserScope, "user")]
          let demoRows = filter ((== "demo") . view #name) rows
          assertBool "expected demo status rows" (not (null demoRows))
          mapM_ (\row -> row ^. #conditions @?= [KitDelisted]) demoRows
          mapM_ (\row -> row ^. #installedVersion @?= Just "0.1.0") demoRows,
      testCase "version and cached hash drift reports outdated+changed-upstream" $
        withPreparedKitHome $ \_home cache -> do
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          BS.writeFile (cache </> "skills" </> "demo" </> "SKILL.md") "changed instructions\n"
          BS.writeFile (cache </> "kit.json") manifestWithDemoVersionJson
          rows <- collectStatus testConfig cache [(UserScope, "user")]
          let demoRows = filter ((== "demo") . view #name) rows
          assertBool "expected demo status rows" (not (null demoRows))
          mapM_ (\row -> row ^. #conditions @?= [KitOutdated, KitChangedUpstream]) demoRows,
      testCase "an installed item reports no conditions before an edit" $
        withPreparedKitHome $ \_home cache -> do
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          rows <- collectStatus testConfig cache [(UserScope, "user")]
          let demoRows = filter ((== "demo") . view #name) rows
          assertBool "expected demo status rows" (not (null demoRows))
          mapM_ (\row -> row ^. #conditions @?= []) demoRows,
      testCase "editing an installed file reports modified" $
        withPreparedKitHome $ \home cache -> do
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          BS.writeFile (userClaudeSkill home </> "SKILL.md") "my edits"
          rows <- collectStatus testConfig cache [(UserScope, "user")]
          demoConditions rows "claude" >>= (@?= [KitLocallyModified])
          demoConditions rows "codex" >>= (@?= []),
      testCase "a legacy sidecar reports edits-unknown" $
        withPreparedKitHome $ \home cache -> do
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          BS.writeFile (userClaudeSkill home </> ".testkit-kit.json") legacySidecarJson
          rows <- collectStatus testConfig cache [(UserScope, "user")]
          conditions <- demoConditions rows "claude"
          assertBool ("expected edits-unknown in " <> show conditions) (KitLocalEditsUnknown `elem` conditions)
          assertBool ("expected no modified in " <> show conditions) (KitLocallyModified `notElem` conditions),
      testCase "modified composes with outdated and changed-upstream" $
        withPreparedKitHome $ \home cache -> do
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          BS.writeFile (userClaudeSkill home </> "SKILL.md") "my edits"
          BS.writeFile (cache </> "skills" </> "demo" </> "SKILL.md") "changed instructions\n"
          BS.writeFile (cache </> "kit.json") manifestWithDemoVersionJson
          rows <- collectStatus testConfig cache [(UserScope, "user")]
          demoConditions rows "claude" >>= (@?= [KitOutdated, KitChangedUpstream, KitLocallyModified]),
      testCase "status reports modified for exactly what update would skip" $
        withPreparedKitHome $ \home cache -> do
          -- Keep project scope inside the temporary HOME so the update's
          -- project-scope scan never looks at the working directory.
          let config = testConfig & #projectRoot .~ pure (home </> "project")
          _ <- assertRight =<< installItem config "demo" UserScope
          _ <- assertRight =<< installItem config "reviewer" UserScope
          BS.writeFile (userClaudeSkill home </> "SKILL.md") "my edits"
          rows <- collectStatus config cache [(UserScope, "user"), (ProjectScope, "project")]
          let toScope scopeText = if scopeText == "project" then ProjectScope else UserScope
              modifiedByStatus =
                nub
                  [ (row ^. #name, toScope (row ^. #scope))
                  | row <- rows,
                    KitLocallyModified `elem` row ^. #conditions
                  ]
          manifest <- assertRight =<< loadManifest cache
          report <- assertRight =<< reinstallPresent config cache manifest Nothing KeepLocalEdits
          sort (report ^. #skipped) @?= sort modifiedByStatus
          modifiedByStatus @?= [("demo", UserScope)]
    ]
  where
    userClaudeSkill home = home </> ".config" </> "testkit" </> "agents" </> ".claude" </> "skills" </> "demo"
    demoConditions rows providerText =
      case filter (\row -> row ^. #name == "demo" && row ^. #providers == providerText) rows of
        [row] -> pure (row ^. #conditions)
        other -> assertFailure ("expected one " <> Text.unpack providerText <> " demo row, got " <> show other)

installRoundTripTests :: TestTree
installRoundTripTests =
  testGroup
    "Install"
    [ testCase "skill and agent round-trip through Claude and Codex layouts with sidecars" $
        withPreparedKitHome $ \home _cache -> do
          let config = testConfig
              claudeBase = home </> ".config" </> "testkit" </> "agents"
              codexBase = home
              claudeSkill = claudeBase </> ".claude" </> "skills" </> "demo"
              codexSkill = codexBase </> ".agents" </> "skills" </> "demo"
              claudeAgent = claudeBase </> ".claude" </> "agents" </> "reviewer.md"
              codexAgent = codexBase </> ".codex" </> "agents" </> "reviewer.toml"
              claudeAgentSidecar = claudeBase </> ".claude" </> "agents" </> "reviewer.testkit-kit.json"
              codexAgentSidecar = codexBase </> ".codex" </> "agents" </> "reviewer.testkit-kit.json"
          _ <- assertRight =<< installItem config "demo" UserScope
          assertFileExists (claudeSkill </> "SKILL.md")
          assertFileExists (codexSkill </> "SKILL.md")
          assertFileExists (claudeSkill </> ".testkit-kit.json")
          meta <- readSidecar (claudeSkill </> ".testkit-kit.json")
          case meta of
            Just sidecar -> do
              (sidecar ^. #name) @?= ("demo" :: Text)
              (sidecar ^. #kind) @?= ("skill" :: Text)
            Nothing -> assertFailure "expected a skill sidecar"
          _ <- assertRight =<< uninstallItem config "demo" UserScope
          assertDirectoryMissing claudeSkill
          assertDirectoryMissing codexSkill
          _ <- assertRight =<< installItem config "reviewer" UserScope
          assertFileExists claudeAgent
          assertFileExists codexAgent
          assertFileExists claudeAgentSidecar
          assertFileExists codexAgentSidecar
          toml <- Text.Encoding.decodeUtf8 <$> BS.readFile codexAgent
          assertBool "Codex agent TOML should contain developer instructions" ("developer_instructions" `Text.isInfixOf` toml)
          _ <- assertRight =<< uninstallItem config "reviewer" UserScope
          assertFileMissing claudeAgent
          assertFileMissing codexAgent
          assertFileMissing claudeAgentSidecar
          assertFileMissing codexAgentSidecar,
      testCase "Codex TOML strips CRLF YAML frontmatter" $
        withPreparedKitHome $ \home cache -> do
          let codexAgent = home </> ".codex" </> "agents" </> "reviewer.toml"
          BS.writeFile (cache </> "agents" </> "reviewer.md") "---\r\nname: reviewer\r\n---\r\nReview carefully.\r\n"
          _ <- assertRight =<< installItem testConfig "reviewer" UserScope
          toml <- Text.Encoding.decodeUtf8 <$> BS.readFile codexAgent
          assertBool "frontmatter name should be stripped" (not ("name: reviewer" `Text.isInfixOf` toml))
          assertBool "CR characters should be stripped" (not ("\r" `Text.isInfixOf` toml)),
      testCase "failed provider write rolls back all staged writes" $
        withPreparedKitHome $ \home _cache -> do
          let claudeBase = home </> ".config" </> "testkit" </> "agents"
              claudeAgent = claudeBase </> ".claude" </> "agents" </> "reviewer.md"
              claudeAgentSidecar = claudeBase </> ".claude" </> "agents" </> "reviewer.testkit-kit.json"
          BS.writeFile (home </> ".codex") ""
          result <- installItem testConfig "reviewer" UserScope
          assertKitError "KitWriteFailed" isWriteFailed result
          assertFileMissing claudeAgent
          assertFileMissing claudeAgentSidecar
          tmpFiles <- findFilesWithSuffix home ".baikai-kit-tmp"
          tmpFiles @?= [],
      testCase "renderUninstallReport names actual assets and stale metadata" $ do
        renderUninstallReport "demo" UserScope [RemovalOutcome InteractiveClaude True False False]
          @?= "Uninstalled skill 'demo' from user scope (claude)."
        renderUninstallReport "demo" UserScope [RemovalOutcome InteractiveClaude True False False, RemovalOutcome InteractiveCodex True False False]
          @?= "Uninstalled skill 'demo' from user scope (claude,codex)."
        renderUninstallReport "reviewer" UserScope [RemovalOutcome InteractiveClaude False False True]
          @?= "Removed stale kit metadata for 'reviewer' from user scope."
        renderUninstallReport "demo" UserScope [RemovalOutcome InteractiveClaude False False False]
          @?= "'demo' is not installed in user scope.",
      testCase "uninstallItem reports per-provider removals" $
        withPreparedKitHome $ \home _cache -> do
          let codexSkill = home </> ".agents" </> "skills" </> "demo"
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          removeDirectoryRecursive codexSkill
          outcomes <- assertRight =<< uninstallItem testConfig "demo" UserScope
          let claudeOutcome = findOutcome InteractiveClaude outcomes
              codexOutcome = findOutcome InteractiveCodex outcomes
          view #skillRemoved claudeOutcome @?= True
          view #skillRemoved codexOutcome @?= False
          view #agentRemoved codexOutcome @?= False
          view #sidecarRemoved codexOutcome @?= False,
      testCase "pull failure is returned as a typed error" $
        withPreparedKitHome $ \_home cache -> do
          result <- pullKitRepo testConfig cache
          case result of
            PullFailed _ -> pure ()
            PullSucceeded -> assertFailure "expected fake .git cache pull to fail"
          updateResult <- updateKit testConfig Nothing KeepLocalEdits
          assertKitError "KitPullFailed" isPullFailed updateResult
    ]

typedErrorTests :: TestTree
typedErrorTests =
  testGroup
    "Typed errors"
    [ testCase "loadManifest returns typed errors" $
        withSystemTempDirectory "baikai-kit-manifest" $ \dir -> do
          missing <- loadManifest dir
          assertKitError "KitManifestMissing" isManifestMissing missing
          BS.writeFile (dir </> "kit.json") "{"
          invalid <- loadManifest dir
          assertKitError "KitManifestInvalid" isManifestInvalid invalid,
      testCase "installItem returns KitItemNotFound" $
        withPreparedKitHome $ \_home _cache -> do
          result <- installItem testConfig "nope" UserScope
          assertKitError "KitItemNotFound" (== KitItemNotFound "nope") result,
      testCase "kit status offline on a fresh HOME exits 0" $
        withSystemTempDirectory "baikai-kit-offline" $ \tmp -> do
          oldHome <- lookupEnv "HOME"
          let home = tmp </> "home"
              config = testConfig & #repoUrl .~ "file:///nonexistent-kit"
          createDirectoryIfMissing True home
          setEnv "HOME" home
          flip finally (restoreHome oldHome) $ do
            exitResult <- try @ExitCode (runKit config KitStatus)
            exitResult @?= Right ()
            report <- kitStatus config
            (report ^. #rows) @?= []
            case report ^. #upstream of
              UpstreamUnavailable (KitCloneFailed _ _) -> pure ()
              other -> assertFailure ("expected an unavailable upstream, got " <> show other)
    ]

installFidelityTests :: TestTree
installFidelityTests =
  testGroup
    "Install fidelity"
    [ testCase "multi-file agent installs every listed file" $
        withPreparedKitHome $ \home cache -> do
          plantMultiFileAgent cache
          let claudeBase = home </> ".config" </> "testkit" </> "agents"
              claudeAgents = claudeBase </> ".claude" </> "agents"
              codexAgents = home </> ".codex" </> "agents"
          _ <- assertRight =<< installItem testConfig "reviewer" UserScope
          assertFileExists (claudeAgents </> "reviewer.md")
          assertFileExists (claudeAgents </> "reviewer" </> "guide.md")
          assertFileExists (codexAgents </> "reviewer.toml")
          assertFileExists (codexAgents </> "reviewer" </> "guide.md")
          meta <- readSidecar (claudeAgents </> "reviewer.testkit-kit.json")
          case meta of
            Just sidecar -> (sidecar ^. #installedFiles) @?= Just ["reviewer.md", "reviewer" <> "/" <> "guide.md"]
            Nothing -> assertFailure "expected an agent sidecar"
          _ <- assertRight =<< uninstallItem testConfig "reviewer" UserScope
          assertDirectoryMissing (claudeAgents </> "reviewer")
          assertDirectoryMissing (codexAgents </> "reviewer"),
      testCase "phase-two failure restores the previous files" $
        withSystemTempDirectory "baikai-kit-journal" $ \dir -> do
          BS.writeFile (dir </> "a.txt") "old"
          let writes =
                [ PlannedWrite {destination = dir </> "a.txt", content = WriteBytes "new"},
                  PlannedWrite {destination = dir </> "b.txt", content = WriteBytes "new"}
                ]
              failingRename temp dest
                | "b.txt" `isSuffixOf` dest = do
                    takeDirectory temp @?= dir
                    assertBool "temporary should keep the tmp suffix" (".baikai-kit-tmp" `isSuffixOf` temp)
                    assertBool "temporary name should be unique" (temp /= dest <> ".baikai-kit-tmp")
                    ioError (userError "boom")
                | otherwise = renameFile temp dest
          result <- executePlanWith failingRename writes
          case result of
            Left (KitWriteFailed _ restored broken) -> do
              restored @?= [dir </> "a.txt"]
              broken @?= []
            other -> assertFailure ("expected KitWriteFailed, got " <> show other)
          kept <- BS.readFile (dir </> "a.txt")
          kept @?= "old"
          assertFileMissing (dir </> "b.txt")
          tmpFiles <- findFilesWithSuffix dir ".baikai-kit-tmp"
          tmpFiles @?= []
          bakFiles <- findFilesWithSuffix dir ".baikai-kit-bak"
          bakFiles @?= [],
      testCase "destination directory is refused before any write" $
        withPreparedKitHome $ \home _cache -> do
          let claudeAgents = home </> ".config" </> "testkit" </> "agents" </> ".claude" </> "agents"
          createDirectoryIfMissing True (claudeAgents </> "reviewer.md")
          result <- installItem testConfig "reviewer" UserScope
          assertKitError "KitWriteFailed" isWriteFailed result
          assertFileMissing (home </> ".codex" </> "agents" </> "reviewer.toml"),
      testCase "unsupported manifest version is refused" $
        withPreparedKitHome $ \_home cache -> do
          BS.writeFile (cache </> "kit.json") manifestWithUnsupportedVersionJson
          loaded <- loadManifest cache
          case loaded of
            Left (KitManifestVersionUnsupported _ 99) -> pure ()
            other -> assertFailure ("expected KitManifestVersionUnsupported 99, got " <> show other)
          installed <- installItem testConfig "demo" UserScope
          assertKitError "KitManifestVersionUnsupported" isVersionUnsupported installed,
      testCase "a sidecar written before the installed-file fields still decodes" $
        case Aeson.eitherDecodeStrict' legacySidecarJson :: Either String SidecarMeta of
          Right meta -> do
            (meta ^. #name) @?= ("demo" :: Text)
            (meta ^. #installedFiles) @?= Nothing
            (meta ^. #installedHash) @?= Nothing
          Left err -> assertFailure ("expected a legacy sidecar to decode: " <> err),
      testCase "update skips locally modified items unless forced" $
        withPreparedKitHome $ \home cache -> do
          let claudeSkill = home </> ".config" </> "testkit" </> "agents" </> ".claude" </> "skills" </> "demo"
              upstream = cache </> "skills" </> "demo" </> "SKILL.md"
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          BS.writeFile (claudeSkill </> "SKILL.md") "my edits"
          BS.writeFile upstream "new upstream"
          manifest <- assertRight =<< loadManifest cache
          kept <- assertRight =<< reinstallPresent testConfig cache manifest (Just "demo") KeepLocalEdits
          (kept ^. #skipped) @?= [("demo", UserScope)]
          (kept ^. #updated) @?= []
          mine <- BS.readFile (claudeSkill </> "SKILL.md")
          mine @?= "my edits"
          forced <- assertRight =<< reinstallPresent testConfig cache manifest (Just "demo") OverwriteLocalEdits
          (forced ^. #updated) @?= [("demo", UserScope)]
          (forced ^. #skipped) @?= []
          fresh <- BS.readFile (claudeSkill </> "SKILL.md")
          fresh @?= "new upstream"
          -- A sidecar from before this release records no installed hash,
          -- so the item is reinstalled without the check.
          BS.writeFile (claudeSkill </> ".testkit-kit.json") legacySidecarJson
          BS.writeFile (claudeSkill </> "SKILL.md") "my edits again"
          legacy <- assertRight =<< reinstallPresent testConfig cache manifest (Just "demo") KeepLocalEdits
          (legacy ^. #updated) @?= [("demo", UserScope)]
          (legacy ^. #skipped) @?= [],
      testCase "a write failure during update is returned, not thrown" $
        withPreparedKitHome $ \home _cache -> do
          let claudeAgents = home </> ".config" </> "testkit" </> "agents" </> ".claude" </> "agents"
              cache = home </> ".cache" </> "testkit" </> "kit"
          _ <- assertRight =<< installItem testConfig "reviewer" UserScope
          removeFile (claudeAgents </> "reviewer.md")
          createDirectoryIfMissing True (claudeAgents </> "reviewer.md")
          manifest <- assertRight =<< loadManifest cache
          result <- reinstallPresent testConfig cache manifest (Just "reviewer") OverwriteLocalEdits
          assertKitError "KitWriteFailed" isWriteFailed result
    ]

decodeFixture :: FilePath -> IO KitManifest
decodeFixture file = do
  bytes <- BS.readFile ("test/fixtures" </> file)
  case Aeson.eitherDecodeStrict' bytes of
    Right manifest -> pure manifest
    Left err -> assertFailure ("failed to decode " <> file <> ": " <> err)

mkSidecar :: Maybe Text -> Text -> SidecarMeta
mkSidecar mVersion h =
  SidecarMeta
    { name = "foo",
      kind = "skill",
      version = mVersion,
      hash = h,
      installedAt = "2026-05-13T00:00:00Z",
      installedFiles = Nothing,
      installedHash = Nothing
    }

mkSkillItem :: Text -> Maybe Text -> KitItem
mkSkillItem n mVersion =
  KitSkillItem
    SkillEntry
      { name = n,
        description = "x",
        version = mVersion,
        path = "skills/foo",
        files = ["SKILL.md"]
      }

mkAgentItem :: Text -> Maybe Text -> KitItem
mkAgentItem n mVersion =
  KitAgentItem
    AgentEntry
      { name = n,
        description = "x",
        version = mVersion,
        path = "agents/foo.md",
        files = Nothing
      }

commandTests :: TestTree
commandTests =
  testGroup
    "Command"
    [ testCase "install parses with and without a name" $ do
        parse ["install"] @?= Just (KitInstall Nothing UserScope)
        parse ["install", "demo", "--project"] @?= Just (KitInstall (Just "demo") ProjectScope)
        parse [] @?= Just KitList,
      testCase "install help names the tool's project directory" $
        case execParserPure defaultPrefs (info (kitCommandParser testConfig <**> helper) mempty) ["install", "--help"] of
          Failure failure -> do
            let rendered = fst (renderFailure failure "kit")
            assertBool ("expected .testkit/agents in help:\n" <> rendered) (".testkit/agents" `isInfixOf` rendered)
          _ -> assertFailure "expected --help to produce help text",
      testCase "install with no name and no chooser is a KitItemNameRequired error" $ do
        result <- runKitCommand testConfig (KitInstall Nothing UserScope)
        result @?= Left KitItemNameRequired
        exitResult <- try @ExitCode (runKit testConfig (KitInstall Nothing UserScope))
        exitResult @?= Left (ExitFailure 1),
      testCase "install with no name installs what the chooser returns" $
        withPreparedKitHome $ \home _cache -> do
          seen <- newIORef []
          let chooser manifest = do
                writeIORef seen (map (view #name) (manifest ^. #skills) ++ map (view #name) (manifest ^. #agents))
                pure (Just "demo")
              config = testConfig & #chooseItem .~ Just chooser
          result <- runKitCommand config (KitInstall Nothing UserScope)
          result @?= Right ()
          assertFileExists (userClaudeDemo home </> "SKILL.md")
          readIORef seen >>= (@?= ["demo", "reviewer"]),
      testCase "a cancelled choice installs nothing and succeeds" $
        withPreparedKitHome $ \home _cache -> do
          let config = testConfig & #chooseItem .~ Just (\_ -> pure Nothing)
          result <- runKitCommand config (KitInstall Nothing UserScope)
          result @?= Right ()
          assertDirectoryMissing (userClaudeDemo home)
          exitResult <- try @ExitCode (runKit config (KitInstall Nothing UserScope))
          exitResult @?= Right ()
          assertDirectoryMissing (userClaudeDemo home),
      testCase "a chosen name the manifest lacks is KitItemNotFound" $
        withPreparedKitHome $ \_home _cache -> do
          let config = testConfig & #chooseItem .~ Just (\_ -> pure (Just "nope"))
          result <- runKitCommand config (KitInstall Nothing UserScope)
          result @?= Left (KitItemNotFound "nope")
    ]
  where
    parse = getParseResult . execParserPure defaultPrefs (info (kitCommandParser testConfig) mempty)
    userClaudeDemo home = home </> ".config" </> "testkit" </> "agents" </> ".claude" </> "skills" </> "demo"

projectRootTests :: TestTree
projectRootTests =
  testGroup
    "Project root"
    [ testCase "findProjectRoot walks up from a nested directory" $
        withMarkedTree $ \root -> do
          found <- findProjectRoot [rootMarker] (root </> "a" </> "b")
          found @?= Just root,
      testCase "findProjectRoot accepts a start directory that is itself the root" $
        withMarkedTree $ \root -> do
          found <- findProjectRoot [rootMarker] root
          found @?= Just root,
      testCase "findProjectRoot returns Nothing when no marker exists" $
        withMarkedTree $ \root -> do
          found <- findProjectRoot [".testkit-no-such-marker"] (root </> "a")
          found @?= Nothing
          withCurrentDirectory (root </> "a") $ do
            resolved <- projectRootByMarkers [".testkit-no-such-marker"]
            cwd <- getCurrentDirectory
            resolved @?= cwd,
      testCase "a configured root puts project scope in one place" $
        withPreparedKitHome $ \_home _cache ->
          withProjectTree $ \proj -> do
            let config = testConfig & #projectRoot .~ pure proj
                claudeSkill = proj </> ".testkit" </> "agents" </> ".claude" </> "skills" </> "demo"
            withCurrentDirectory (proj </> "src" </> "deep") $
              void (assertRight =<< installItem config "demo" ProjectScope)
            assertFileExists (claudeSkill </> "SKILL.md")
            assertFileExists (proj </> ".agents" </> "skills" </> "demo" </> "SKILL.md")
            assertDirectoryMissing (proj </> "src" </> "deep" </> ".testkit")
            withCurrentDirectory (proj </> "docs") $ do
              assertProjectRow config
              dirs <- agentDirsForSession config
              assertBool
                ("expected the project agents dir in " <> show dirs)
                ((proj </> ".testkit" </> "agents") `elem` dirs)
              outcomes <- assertRight =<< uninstallItem config "demo" ProjectScope
              let rendered = renderUninstallReport "demo" ProjectScope outcomes
              assertBool
                ("unexpected uninstall report: " <> Text.unpack rendered)
                ("Uninstalled skill 'demo' from project scope" `Text.isPrefixOf` rendered)
            assertDirectoryMissing claudeSkill
            let markerConfig = testConfig & #projectRoot .~ projectRootByMarkers [rootMarker]
            withCurrentDirectory (proj </> "src" </> "deep") $
              void (assertRight =<< installItem markerConfig "demo" ProjectScope)
            assertFileExists (claudeSkill </> "SKILL.md")
            withCurrentDirectory (proj </> "docs") $ assertProjectRow markerConfig,
      testCase "without a resolver, project scope is the current directory" $
        withPreparedKitHome $ \_home _cache ->
          withProjectTree $ \proj ->
            withCurrentDirectory (proj </> "src" </> "deep") $ do
              _ <- assertRight =<< installItem testConfig "demo" ProjectScope
              cwd <- getCurrentDirectory
              assertFileExists (cwd </> ".testkit" </> "agents" </> ".claude" </> "skills" </> "demo" </> "SKILL.md")
              assertDirectoryMissing (proj </> ".testkit")
    ]
  where
    assertProjectRow config = do
      report <- kitStatus config
      let projectRows = filter (\row -> row ^. #name == "demo" && row ^. #scope == "project") (report ^. #rows)
      assertBool "expected a project-scope status row for demo" (not (null projectRows))

-- | A marker no real directory above the system temporary directory can
--   hold, so a walk to the filesystem root cannot find someone's @.git@.
rootMarker :: FilePath
rootMarker = ".testkit-root-marker"

-- | @root/.testkit-root-marker@ and @root/a/b@, with @root@ canonical so
--   it compares equal to paths the resolver builds.
withMarkedTree :: (FilePath -> IO a) -> IO a
withMarkedTree action =
  withSystemTempDirectory "baikai-kit-root" $ \tmp -> do
    root <- (</> "root") <$> canonicalizePath tmp
    createDirectoryIfMissing True (root </> "a" </> "b")
    BS.writeFile (root </> rootMarker) ""
    action root

-- | A project with a root marker, @src/deep@, and @docs@.
withProjectTree :: (FilePath -> IO a) -> IO a
withProjectTree action =
  withSystemTempDirectory "baikai-kit-project" $ \tmp -> do
    proj <- (</> "proj") <$> canonicalizePath tmp
    createDirectoryIfMissing True (proj </> "src" </> "deep")
    createDirectoryIfMissing True (proj </> "docs")
    BS.writeFile (proj </> rootMarker) ""
    action proj

testConfig :: KitConfig
testConfig = kitConfig "testkit" "file:///not-used" [InteractiveClaude, InteractiveCodex]

withPreparedKitHome :: (FilePath -> FilePath -> IO a) -> IO a
withPreparedKitHome action =
  withSystemTempDirectory "baikai-kit-home" $ \tmp -> do
    oldHome <- lookupEnv "HOME"
    let home = tmp </> "home"
        cache = home </> ".cache" </> "testkit" </> "kit"
    createDirectoryIfMissing True (cache </> ".git")
    createDirectoryIfMissing True (cache </> "skills" </> "demo")
    createDirectoryIfMissing True (cache </> "agents")
    BS.writeFile (cache </> "skills" </> "demo" </> "SKILL.md") "skill instructions\n"
    BS.writeFile (cache </> "agents" </> "reviewer.md") "---\nname: reviewer\n---\nReview carefully.\n"
    BS.writeFile (cache </> "kit.json") manifestJson
    setEnv "HOME" home
    action home cache `finally` restoreHome oldHome

restoreHome :: Maybe String -> IO ()
restoreHome Nothing = unsetEnv "HOME"
restoreHome (Just value) = setEnv "HOME" value

-- | Plant a committed-symlink kit: a directory link out of the checkout
--   and a manifest that lists a file below it.
plantSymlinkedSource :: FilePath -> FilePath -> IO ()
plantSymlinkedSource home cache = do
  let outsideDir = takeDirectory home </> "outside"
  createDirectoryIfMissing True outsideDir
  BS.writeFile (outsideDir </> "secret.txt") "top secret\n"
  createDirectoryLink outsideDir (cache </> "skills" </> "demo" </> "sub")
  BS.writeFile (cache </> "kit.json") manifestWithSymlinkedFileJson

manifestWithSymlinkedFileJson :: BS.ByteString
manifestWithSymlinkedFileJson =
  Text.Encoding.encodeUtf8 $
    Text.concat
      [ "{\"version\":2,",
        "\"skills\":[{",
        "\"name\":\"demo\",",
        "\"description\":\"Demo skill\",",
        "\"version\":\"0.1.0\",",
        "\"path\":\"skills/demo\",",
        "\"files\":[\"SKILL.md\",\"sub/secret.txt\"]",
        "}],",
        "\"agents\":[]} "
      ]

-- | Rewrite the fixture kit so its agent lists two files below a
--   directory of its own.
plantMultiFileAgent :: FilePath -> IO ()
plantMultiFileAgent cache = do
  createDirectoryIfMissing True (cache </> "agents" </> "reviewer")
  BS.writeFile (cache </> "agents" </> "reviewer" </> "reviewer.md") "---\nname: reviewer\n---\nReview carefully.\n"
  BS.writeFile (cache </> "agents" </> "reviewer" </> "guide.md") "How to review.\n"
  BS.writeFile (cache </> "kit.json") manifestWithMultiFileAgentJson

manifestWithMultiFileAgentJson :: BS.ByteString
manifestWithMultiFileAgentJson =
  Text.Encoding.encodeUtf8 $
    Text.concat
      [ "{\"version\":2,",
        "\"skills\":[],",
        "\"agents\":[{",
        "\"name\":\"reviewer\",",
        "\"description\":\"Review agent\",",
        "\"version\":\"0.1.0\",",
        "\"path\":\"agents/reviewer\",",
        "\"files\":[\"reviewer.md\",\"guide.md\"]",
        "}]} "
      ]

manifestWithUnsupportedVersionJson :: BS.ByteString
manifestWithUnsupportedVersionJson =
  Text.Encoding.encodeUtf8 $
    Text.concat
      [ "{\"version\":99,",
        "\"skills\":[{",
        "\"name\":\"demo\",",
        "\"description\":\"Demo skill\",",
        "\"version\":\"0.1.0\",",
        "\"path\":\"skills/demo\",",
        "\"files\":[\"SKILL.md\"]",
        "}],",
        "\"agents\":[]} "
      ]

legacySidecarJson :: BS.ByteString
legacySidecarJson =
  "{\"name\":\"demo\",\"kind\":\"skill\",\"version\":\"0.1.0\",\"hash\":\"sha256:x\",\"installedAt\":\"t\"}"

manifestJson :: BS.ByteString
manifestJson =
  Text.Encoding.encodeUtf8 $
    Text.concat
      [ "{\"version\":2,",
        "\"skills\":[{",
        "\"name\":\"demo\",",
        "\"description\":\"Demo skill\",",
        "\"version\":\"0.1.0\",",
        "\"path\":\"skills/demo\",",
        "\"files\":[\"SKILL.md\"]",
        "}],",
        "\"agents\":[{",
        "\"name\":\"reviewer\",",
        "\"description\":\"Review agent\",",
        "\"version\":\"0.1.0\",",
        "\"path\":\"agents/reviewer.md\"",
        "}]} "
      ]

manifestWithoutDemoJson :: BS.ByteString
manifestWithoutDemoJson =
  Text.Encoding.encodeUtf8 $
    Text.concat
      [ "{\"version\":2,",
        "\"skills\":[],",
        "\"agents\":[{",
        "\"name\":\"reviewer\",",
        "\"description\":\"Review agent\",",
        "\"version\":\"0.1.0\",",
        "\"path\":\"agents/reviewer.md\"",
        "}]} "
      ]

manifestWithDemoVersionJson :: BS.ByteString
manifestWithDemoVersionJson =
  Text.Encoding.encodeUtf8 $
    Text.concat
      [ "{\"version\":2,",
        "\"skills\":[{",
        "\"name\":\"demo\",",
        "\"description\":\"Demo skill\",",
        "\"version\":\"0.2.0\",",
        "\"path\":\"skills/demo\",",
        "\"files\":[\"SKILL.md\"]",
        "}],",
        "\"agents\":[{",
        "\"name\":\"reviewer\",",
        "\"description\":\"Review agent\",",
        "\"version\":\"0.1.0\",",
        "\"path\":\"agents/reviewer.md\"",
        "}]} "
      ]

maliciousManifestJson :: BS.ByteString
maliciousManifestJson =
  Text.Encoding.encodeUtf8 $
    Text.concat
      [ "{\"version\":2,",
        "\"skills\":[{",
        "\"name\":\"evil\",",
        "\"description\":\"Evil skill\",",
        "\"version\":\"0.1.0\",",
        "\"path\":\"skills/demo\",",
        "\"files\":[\"../../../../escape.txt\"]",
        "}],",
        "\"agents\":[]} "
      ]

isUnsafePath :: KitError -> Bool
isUnsafePath = \case KitUnsafePath _ _ -> True; _ -> False

isUnsafeName :: KitError -> Bool
isUnsafeName = \case KitUnsafeName _ _ -> True; _ -> False

isSourceSymlink :: KitError -> Bool
isSourceSymlink = \case KitSourceSymlink _ -> True; _ -> False

isWriteFailed :: KitError -> Bool
isWriteFailed = \case KitWriteFailed {} -> True; _ -> False

isPullFailed :: KitError -> Bool
isPullFailed = \case KitPullFailed _ -> True; _ -> False

isManifestMissing :: KitError -> Bool
isManifestMissing = \case KitManifestMissing _ -> True; _ -> False

isVersionUnsupported :: KitError -> Bool
isVersionUnsupported = \case KitManifestVersionUnsupported _ _ -> True; _ -> False

isManifestInvalid :: KitError -> Bool
isManifestInvalid = \case KitManifestInvalid _ _ -> True; _ -> False

assertKitError :: (Show a) => String -> (KitError -> Bool) -> Either KitError a -> IO ()
assertKitError label matches result =
  case result of
    Left err | matches err -> pure ()
    other -> assertFailure ("expected " <> label <> ", got " <> show other)

assertRight :: (Show e) => Either e a -> IO a
assertRight = \case
  Right value -> pure value
  Left err -> assertFailure ("expected Right, got Left " <> show err)

assertLeft :: (Show b) => Either a b -> IO ()
assertLeft result =
  case result of
    Left _ -> pure ()
    Right value -> assertFailure ("expected Left, got Right " <> show value)

assertFileExists :: FilePath -> IO ()
assertFileExists path = do
  exists <- doesFileExist path
  assertBool ("expected file to exist: " <> path) exists

assertFileMissing :: FilePath -> IO ()
assertFileMissing path = do
  exists <- doesFileExist path
  assertBool ("expected file to be missing: " <> path) (not exists)

assertDirectoryMissing :: FilePath -> IO ()
assertDirectoryMissing path = do
  exists <- doesDirectoryExist path
  assertBool ("expected directory to be missing: " <> path) (not exists)

assertDirectoryExists :: FilePath -> IO ()
assertDirectoryExists path = do
  exists <- doesDirectoryExist path
  assertBool ("expected directory to exist: " <> path) exists

findFilesWithSuffix :: FilePath -> String -> IO [FilePath]
findFilesWithSuffix root suffix = do
  exists <- doesPathExist root
  if not exists
    then pure []
    else do
      isDir <- doesDirectoryExist root
      if not isDir
        then pure [root | suffix `isSuffixOf` root]
        else do
          names <- listDirectory root
          fmap concat $ mapM (\name -> findFilesWithSuffix (root </> name) suffix) names

findOutcome :: InteractiveProvider -> [RemovalOutcome] -> RemovalOutcome
findOutcome expected outcomes =
  case find ((== expected) . view #provider) outcomes of
    Just outcome -> outcome
    Nothing -> error "expected provider outcome"
