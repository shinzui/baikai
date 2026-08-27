{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Baikai.Interactive (InteractiveProvider (InteractiveClaude, InteractiveCodex))
import Baikai.Kit
  ( AgentEntry (..),
    KitCommand (..),
    KitConfig (..),
    KitError (..),
    KitItem (..),
    KitItemKind (..),
    KitManifest (..),
    KitScope (UserScope),
    KitState (..),
    PullResult (..),
    RemovalOutcome (..),
    SidecarMeta (..),
    SkillEntry (..),
    UpstreamAvailability (..),
    classify,
    collectStatus,
    computeKitHash,
    installItem,
    kitStatus,
    loadManifest,
    pullKitRepo,
    readSidecar,
    renderState,
    renderUninstallReport,
    runKit,
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
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.List (find, isSuffixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import System.Directory
  ( createDirectoryIfMissing,
    createDirectoryLink,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    listDirectory,
    removeDirectoryRecursive,
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
          typedErrorTests
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
        classify Nothing (Just (mkSkillItem "foo" (Just "1.0"))) (Just "h") @?= KitUnknown,
      testCase "no upstream entry with a sidecar => delisted" $
        classify (Just (mkSidecar (Just "1.0") "h")) Nothing (Just "h") @?= KitDelisted,
      testCase "version mismatch => outdated" $
        classify
          (Just (mkSidecar (Just "1.0") "h"))
          (Just (mkSkillItem "foo" (Just "2.0")))
          (Just "h")
          @?= KitOutdated,
      testCase "version and hash mismatch => dirty+outdated" $
        classify
          (Just (mkSidecar (Just "1.0") "h1"))
          (Just (mkSkillItem "foo" (Just "2.0")))
          (Just "h2")
          @?= KitDirtyOutdated,
      testCase "hash mismatch => dirty" $
        classify
          (Just (mkSidecar (Just "1.0") "h1"))
          (Just (mkSkillItem "foo" (Just "1.0")))
          (Just "h2")
          @?= KitDirty,
      testCase "version and hash match => up-to-date" $
        classify
          (Just (mkSidecar (Just "1.0") "h"))
          (Just (mkSkillItem "foo" (Just "1.0")))
          (Just "h")
          @?= KitUpToDate,
      testCase "no upstream hash on matching version => up-to-date" $
        classify
          (Just (mkSidecar (Just "1.0") "h"))
          (Just (mkAgentItem "foo" (Just "1.0")))
          Nothing
          @?= KitUpToDate
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
          exitResult <- try @ExitCode (runKit testConfig (KitInstall "evil" UserScope))
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
          mapM_ (\row -> row ^. #state @?= KitUpstreamRefused) demoRows,
      testCase "renderState names the refused state" $
        renderState KitUpstreamRefused @?= "refused"
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
        stripYamlFrontmatter "---\nname: x\nBody.\n" @?= "---\nname: x\nBody.\n"
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
          mapM_ (\row -> row ^. #state @?= KitDelisted) demoRows
          mapM_ (\row -> row ^. #installedVersion @?= Just "0.1.0") demoRows,
      testCase "version and cached hash drift reports dirty+outdated" $
        withPreparedKitHome $ \_home cache -> do
          _ <- assertRight =<< installItem testConfig "demo" UserScope
          BS.writeFile (cache </> "skills" </> "demo" </> "SKILL.md") "changed instructions\n"
          BS.writeFile (cache </> "kit.json") manifestWithDemoVersionJson
          rows <- collectStatus testConfig cache [(UserScope, "user")]
          let demoRows = filter ((== "demo") . view #name) rows
          assertBool "expected demo status rows" (not (null demoRows))
          mapM_ (\row -> row ^. #state @?= KitDirtyOutdated) demoRows
    ]

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
          updateResult <- updateKit testConfig Nothing
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
      installedAt = "2026-05-13T00:00:00Z"
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

testConfig :: KitConfig
testConfig =
  KitConfig
    { toolName = "testkit",
      repoUrl = "file:///not-used",
      providers = [InteractiveClaude, InteractiveCodex]
    }

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
