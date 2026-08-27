-- | Tests that spawn the __built__ @baikai@ executable.
--
-- Every other case in this suite exercises the library in this test
-- binary's own process, under this test binary's own runtime system. A
-- test suite's @ghc-options@ are evidence about the suite and about
-- nothing else, so a suite compiled @-threaded@ can pass every runner
-- case while the installed executable, compiled without it, cannot keep
-- the same contract: in the non-threaded runtime a blocking operating
-- system call such as the @waitpid@ inside 'System.Process.waitForProcess'
-- stops every Haskell thread until it returns, so the timeout can never
-- fire and a child that fills a pipe deadlocks against its parent.
--
-- The cases here therefore run the real binary, as a user who typed
-- @cabal install baikai-agent@ would.
module BinaryTests (binaryTests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    findExecutable,
    getPermissions,
    setOwnerExecutable,
    setPermissions,
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as P
import System.Timeout qualified as Timeout
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

binaryTests :: TestTree
binaryTests =
  testGroup
    "the built baikai binary"
    [ reportsTheThreadedRuntimeTest,
      timesOutAHungAgentTest,
      writesUtf8UnderCLocaleTest
    ]

-- --------------------------------------------------------------------
-- Locating and running the executable
-- --------------------------------------------------------------------

-- | The built executable.
--
-- Under @cabal test@ the @build-tool-depends: baikai-agent:baikai@ entry
-- on this suite makes cabal build the executable first and put its
-- directory on the @PATH@ of the process that runs this binary, so a
-- plain 'findExecutable' finds the freshly built one.
-- @BAIKAI_AGENT_TEST_EXECUTABLE@ overrides that for a test binary run by
-- hand, for example
-- @BAIKAI_AGENT_TEST_EXECUTABLE=$(cabal list-bin baikai-agent:exe:baikai)@.
--
-- Absence is a hard failure rather than a skip: a silent skip here would
-- turn the one case that proves what the binary ships with into no case
-- at all.
builtBaikai :: IO FilePath
builtBaikai = do
  override <- lookupEnv "BAIKAI_AGENT_TEST_EXECUTABLE"
  found <- maybe (findExecutable "baikai") (pure . Just) override
  maybe
    ( assertFailure
        "no baikai executable found: run this suite through `cabal test`, \
        \or set BAIKAI_AGENT_TEST_EXECUTABLE to the built binary"
    )
    pure
    found

-- | Run the executable and collect everything it wrote.
--
-- The environment is explicit: @PATH@ from this process (the child needs
-- @sh@, and under @cabal test@ that @PATH@ is also how the stub scripts
-- find their own tools), and @HOME@ and @XDG_CONFIG_HOME@ pointing at
-- the temporary directory so that a developer's real
-- @~\/.config\/baikai\/agents.kdl@ is never consulted. Anything a case
-- adds wins over those defaults.
--
-- Both output pipes are drained on forked threads before the wait, for
-- the same reason the runner itself does it: a pipe holds a bounded
-- amount of data and a parent that waits first deadlocks a chatty child.
runBaikai ::
  FilePath ->
  [String] ->
  [(String, String)] ->
  FilePath ->
  IO (ExitCode, ByteString, ByteString)
runBaikai exe args extraEnv workingDir = do
  parentPath <- fromMaybe "/usr/bin:/bin" <$> lookupEnv "PATH"
  let environment =
        [ ("PATH", parentPath),
          ("HOME", workingDir),
          ("XDG_CONFIG_HOME", workingDir)
        ]
          <> extraEnv
      spec =
        (P.proc exe args)
          { P.cwd = Just workingDir,
            P.env = Just environment,
            P.std_in = P.NoStream,
            P.std_out = P.CreatePipe,
            P.std_err = P.CreatePipe
          }
  P.withCreateProcess spec $ \_ mOut mErr ph -> do
    outVar <- drainAsync mOut
    errVar <- drainAsync mErr
    code <- P.waitForProcess ph
    out <- takeMVar outVar
    err <- takeMVar errVar
    pure (code, out, err)

-- | Read one handle to end of file on its own thread.
drainAsync :: Maybe Handle -> IO (MVar ByteString)
drainAsync Nothing = newMVar BS.empty
drainAsync (Just h) = do
  var <- newEmptyMVar
  _ <- forkIO (BS.hGetContents h >>= putMVar var)
  pure var

-- --------------------------------------------------------------------
-- The runtime probe
-- --------------------------------------------------------------------

-- | @+RTS --info@ prints the runtime the binary was linked against.
--
-- The @RTS way@ entry reads @rts_thr@ for the threaded runtime; a binary
-- built without @-threaded@ reads @rts_v@. Only the way name is asserted,
-- because the surrounding spacing of the printed pair is GHC's to change
-- (9.12.4 prints @(\"RTS way\", \"rts_thr\")@, with a space). The probe
-- itself is permitted under GHC's default @-rtsopts=some@, so the
-- executable needs no @-rtsopts@ of its own for this to work.
reportsTheThreadedRuntimeTest :: TestTree
reportsTheThreadedRuntimeTest =
  testCase "baikai +RTS --info reports the threaded runtime" $
    withSystemTempDirectory "baikai-agent-binary" $ \dir -> do
      exe <- builtBaikai
      (_, out, _) <- runBaikai exe ["+RTS", "--info"] [] dir
      assertBool
        ( "expected the threaded runtime in `baikai +RTS --info`; a stale or \
          \unthreaded binary reports rts_v. Output was:\n"
            <> BS8.unpack out
        )
        (BS8.pack "\"rts_thr\"" `BS.isInfixOf` out)

-- --------------------------------------------------------------------
-- The timeout, on the shipped runtime
-- --------------------------------------------------------------------

-- | A stub coding agent that outlives its timeout.
--
-- It records its own process id and the process id of a background
-- @sleep@ so the case can prove the whole process group was reached,
-- prints one line so the case can prove drained output survives, and
-- then waits for a child that will not return for two minutes.
hangingStub :: Text
hangingStub =
  Text.pack
    ( unlines
        [ "#!/bin/sh",
          -- Ignoring both polite signals is what makes this case prove
          -- the escalation rather than the first signal: SIGKILL is the
          -- only thing left that can end this shell, and the ignored
          -- disposition is inherited by the background sleep too.
          "trap '' INT TERM",
          "echo \"$$\" > \"$BAIKAI_TEST_PIDFILE\"",
          "printf 'partial output before the hang\\n'",
          "sleep 120 &",
          "echo \"$!\" >> \"$BAIKAI_TEST_PIDFILE\"",
          "wait"
        ]
    )

-- | An operator-scope job that runs the stub under a short deadline.
--
-- Operator scope rather than repository scope on purpose: the policy
-- ceiling is loaded from the operator file, so a job that names its own
-- @executable@ is safe here whatever the repository scope is later
-- allowed to set.
--
-- Three seconds rather than one. The deadline has to clear the time the
-- operating system takes to start @\/bin\/sh@ while the rest of this
-- suite runs in parallel, and one second does not: with @timeout \"1s\"@
-- this case fails on a loaded machine having never created the process
-- id file at all, because the stub's first line had not run when the
-- group was killed. Three seconds is still forty times shorter than the
-- stub's own sleep, so what the case proves — that the deadline stopped
-- the child rather than the child finishing — is unchanged.
captureJob :: String -> FilePath -> FilePath -> String -> String
captureJob jobName executable workspace deadline =
  unlines
    [ "jobs {",
      "  " <> jobName <> " {",
      "    provider \"claude\"",
      "    executable \"" <> executable <> "\"",
      "    working-dir \"" <> workspace <> "\"",
      "    output \"capture\"",
      "    timeout \"" <> deadline <> "\"",
      "    safety { capability \"read-only\" }",
      "  }",
      "}"
    ]

timesOutAHungAgentTest :: TestTree
timesOutAHungAgentTest =
  testCase "agent run stops a child that outlives its timeout, exit 75" $
    withSystemTempDirectory "baikai-agent-binary" $ \dir -> do
      exe <- builtBaikai
      let workspace = dir </> "workspace"
          stub = dir </> "hang.sh"
          pidFile = dir </> "pids"
          configPath = dir </> "agents.kdl"
      createDirectoryIfMissing True workspace
      writeExecutable stub hangingStub
      writeFile configPath (captureJob "hang" stub workspace "3s")
      started <- getCurrentTime
      -- Bounded so that the pre-fix behaviour — a timeout that can never
      -- fire — fails in thirty seconds instead of waiting out the
      -- stub's two-minute sleep.
      outcome <-
        Timeout.timeout 30000000 $
          runBaikai
            exe
            [ "agent",
              "run",
              "hang",
              "--prompt",
              "go",
              "--user-config",
              configPath
            ]
            [("BAIKAI_TEST_PIDFILE", pidFile)]
            dir
      finished <- getCurrentTime
      let elapsed = diffUTCTime finished started
      case outcome of
        Nothing ->
          assertFailure
            "the run never returned: the configured timeout did not stop the \
            \child. This is what an executable built without -threaded does, \
            \because waitForProcess blocks every Haskell thread."
        Just (code, out, err) -> do
          assertBool
            ( "expected exit 75 (the timeout code). stdout:\n"
                <> BS8.unpack out
                <> "\nstderr:\n"
                <> BS8.unpack err
            )
            (code == ExitFailure 75)
          assertBool
            ( "expected the deadline plus the grace periods, not the stub's \
              \own two minutes; the run took "
                <> show elapsed
            )
            (elapsed < 20)
          -- The bytes the stub printed before the kill are reported
          -- rather than discarded, which for a real coding agent is the
          -- partial answer an operator most wants from a timed-out run.
          assertBool
            ("expected the drained line on standard output, got: " <> show out)
            (out == BS8.pack "partial output before the hang\n")
          pids <- recordedPids pidFile
          assertBool
            ( "the stub never recorded a process id, so the case proved \
              \nothing. stdout:\n"
                <> BS8.unpack out
                <> "\nstderr:\n"
                <> BS8.unpack err
            )
            (not (null pids))
          awaitAllGone pids

-- | The process ids the stub wrote, one per line.
recordedPids :: FilePath -> IO [String]
recordedPids path = do
  present <- doesFileExist path
  if not present
    then pure []
    else do
      contents <- readFile path
      pure [line | line <- lines contents, not (null line)]

-- | Fail unless every recorded process is gone.
--
-- Polled rather than checked once: the runner returns as soon as it has
-- reaped the group's leader, and the kernel may take a moment longer to
-- finish reaping a grandchild.
awaitAllGone :: [String] -> IO ()
awaitAllGone pids = go (40 :: Int)
  where
    go n = do
      alive <- filterM' processAlive pids
      case (alive, n) of
        ([], _) -> pure ()
        (remaining, 0) ->
          assertFailure
            ( "these processes outlived the run: "
                <> unwords remaining
                <> " — the timeout did not reach the whole process group"
            )
        (_, _) -> threadDelay 50000 >> go (n - 1)
    filterM' p xs = concat <$> mapM (\x -> (\keep -> [x | keep]) <$> p x) xs

-- | Whether a process exists, asked with the null signal: @kill -0@
-- delivers nothing and fails when no such process is there.
processAlive :: String -> IO Bool
processAlive pid = do
  (code, _, _) <- P.readProcessWithExitCode "kill" ["-0", pid] ""
  pure (code == ExitSuccess)

-- --------------------------------------------------------------------
-- Small helpers
-- --------------------------------------------------------------------

-- | Write a shell script as UTF-8 bytes and make it executable.
--
-- Encoded explicitly rather than written with 'writeFile', which encodes
-- through this process's locale: a stub whose whole purpose is to print
-- non-ASCII text could not otherwise be written at all under @LANG=C@.
writeExecutable :: FilePath -> Text -> IO ()
writeExecutable path body = do
  BS.writeFile path (Text.encodeUtf8 body)
  perms <- getPermissions path
  setPermissions path (setOwnerExecutable True perms)

-- --------------------------------------------------------------------
-- Output encoding, on the shipped binary
-- --------------------------------------------------------------------

-- | What the stub prints, and therefore what the command must print
-- back: a Latin-1-representable letter, a character outside Latin-1, and
-- one outside the Basic Multilingual Plane's Latin range.
utf8Answer :: Text
utf8Answer = Text.pack "réconcilier — 文法"

-- | The command writes UTF-8 whatever the locale says.
--
-- @LANG=C@ is what cron, systemd units, and minimal containers give a
-- process. Before this was fixed the command encoded its output through
-- that locale, so a single non-ASCII character in the agent's answer
-- made the write throw @invalid argument@ /after/ the run had finished:
-- exit 1, and the answer lost.
--
-- The environment is set explicitly and contains no other @LC_@
-- variable, so nothing else can quietly restore a UTF-8 locale.
writesUtf8UnderCLocaleTest :: TestTree
writesUtf8UnderCLocaleTest =
  testCase "the command writes UTF-8 under LANG=C" $
    withSystemTempDirectory "baikai-agent-binary" $ \dir -> do
      exe <- builtBaikai
      let workspace = dir </> "workspace"
          stub = dir </> "say.sh"
          configPath = dir </> "agents.kdl"
      createDirectoryIfMissing True workspace
      writeExecutable
        stub
        (Text.pack "#!/bin/sh\nprintf '" <> utf8Answer <> Text.pack "\\n'\n")
      writeFile configPath (captureJob "say" stub workspace "30s")
      (code, out, err) <-
        runBaikai
          exe
          ["agent", "run", "say", "--prompt", "go", "--user-config", configPath]
          [("LANG", "C"), ("LC_ALL", "C")]
          dir
      assertBool
        ("expected a successful run; stderr was:\n" <> BS8.unpack err)
        (code == ExitSuccess)
      out @?= Text.encodeUtf8 (utf8Answer <> Text.pack "\n")
