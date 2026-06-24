{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Baikai.Interactive (InteractiveProvider (InteractiveClaude, InteractiveCodex))
import Baikai.Kit
  ( AgentEntry (..),
    KitConfig (..),
    KitItem (..),
    KitManifest (..),
    KitScope (UserScope),
    KitState (..),
    SidecarMeta (..),
    SkillEntry (..),
    classify,
    computeKitHash,
    installItem,
    readSidecar,
    uninstallItem,
  )
import Baikai.Prelude
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "baikai-kit"
      [ manifestTests,
        hashTests,
        classifyTests,
        installRoundTripTests
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
          h1 <- computeKitHash dir ["a.md", "b.md", "c.md"]
          h2 <- computeKitHash dir ["c.md", "a.md", "b.md"]
          h1 @?= h2
          assertBool "hash should carry sha256 prefix" ("sha256:" `Text.isPrefixOf` h1),
      testCase "computeKitHash changes when file content changes" $
        withSystemTempDirectory "baikai-kit-hash-mut" $ \dir -> do
          BS.writeFile (dir </> "a.md") "alpha"
          before <- computeKitHash dir ["a.md"]
          BS.writeFile (dir </> "a.md") "alpha-modified"
          after <- computeKitHash dir ["a.md"]
          assertBool "hashes must differ after content change" (before /= after)
    ]

classifyTests :: TestTree
classifyTests =
  testGroup
    "Status.classify"
    [ testCase "no sidecar => unknown" $
        classify Nothing (Just (mkSkillItem "foo" (Just "1.0"))) (Just "h") @?= KitUnknown,
      testCase "no upstream entry => unknown" $
        classify (Just (mkSidecar (Just "1.0") "h")) Nothing (Just "h") @?= KitUnknown,
      testCase "version mismatch => outdated" $
        classify
          (Just (mkSidecar (Just "1.0") "h"))
          (Just (mkSkillItem "foo" (Just "2.0")))
          (Just "h")
          @?= KitOutdated,
      testCase "version mismatch beats hash mismatch => outdated" $
        classify
          (Just (mkSidecar (Just "1.0") "h1"))
          (Just (mkSkillItem "foo" (Just "2.0")))
          (Just "h2")
          @?= KitOutdated,
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
          installItem config "demo" UserScope
          assertFileExists (claudeSkill </> "SKILL.md")
          assertFileExists (codexSkill </> "SKILL.md")
          assertFileExists (claudeSkill </> ".testkit-kit.json")
          meta <- readSidecar (claudeSkill </> ".testkit-kit.json")
          case meta of
            Just sidecar -> do
              (sidecar ^. #name) @?= ("demo" :: Text)
              (sidecar ^. #kind) @?= ("skill" :: Text)
            Nothing -> assertFailure "expected a skill sidecar"
          uninstallItem config "demo" UserScope
          assertDirectoryMissing claudeSkill
          assertDirectoryMissing codexSkill
          installItem config "reviewer" UserScope
          assertFileExists claudeAgent
          assertFileExists codexAgent
          assertFileExists claudeAgentSidecar
          assertFileExists codexAgentSidecar
          toml <- Text.Encoding.decodeUtf8 <$> BS.readFile codexAgent
          assertBool "Codex agent TOML should contain developer instructions" ("developer_instructions" `Text.isInfixOf` toml)
          uninstallItem config "reviewer" UserScope
          assertFileMissing claudeAgent
          assertFileMissing codexAgent
          assertFileMissing claudeAgentSidecar
          assertFileMissing codexAgentSidecar
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
    action home cache <* restoreHome oldHome
  where
    restoreHome Nothing = unsetEnv "HOME"
    restoreHome (Just value) = setEnv "HOME" value

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
