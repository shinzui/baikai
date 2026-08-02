let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/a3c59033a08c2eaef2cfba4a3c99fc9c192ca6d7/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "baikai"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , description = Some
          "Unified Haskell interface for working with multiple AI providers"
      , domains = [ "AI", "Provider Abstraction" ]
      , owners = [ "shinzui" ]
      }
    , repos = [ Schema.Repo::{ name = "baikai" } ]
    , packages =
      [ Schema.Package::{
        , name = "baikai"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "baikai"
        , description = Some
            "Core abstraction: Provider class, Request/Response, Usage, Cost, error model"
        }
      , Schema.Package::{
        , name = "baikai-claude"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "baikai-claude"
        , description = Some
            "Anthropic Claude providers (API and claude -p CLI) for the Baikai abstraction"
        , dependencies = [ Schema.Dependency.ByName "shinzui/baikai:baikai" ]
        }
      , Schema.Package::{
        , name = "baikai-openai"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "baikai-openai"
        , description = Some
            "OpenAI providers (Chat Completions API and codex CLI) for the Baikai abstraction"
        , dependencies = [ Schema.Dependency.ByName "shinzui/baikai:baikai" ]
        }
      , Schema.Package::{
        , name = "baikai-smoke"
        , type = Schema.PackageType.Other "TestSuite"
        , language = Schema.Language.Haskell
        , path = Some "baikai-smoke"
        , description = Some
            "Live smoke tests across every shipped Baikai provider"
        , visibility = Schema.Visibility.Internal
        , dependencies =
          [ Schema.Dependency.ByName "shinzui/baikai:baikai"
          , Schema.Dependency.ByName "shinzui/baikai:baikai-claude"
          , Schema.Dependency.ByName "shinzui/baikai:baikai-openai"
          ]
        }
      , Schema.Package::{
        , name = "baikai-effectful"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "baikai-effectful"
        , description = Some
            "effectful binding for the baikai transport: the Baikai effect and interpreters"
        , dependencies = [ Schema.Dependency.ByName "shinzui/baikai:baikai" ]
        }
      ]
    , dependencies =
      [ "MercuryTechnologies/claude"
      , "MercuryTechnologies/openai"
      , "garnix-io/cradle"
      , "composewell/streamly"
      , "haskell-servant/servant"
      , "snoyberg/http-client"
      , "ekmett/lens"
      ]
    , docs =
      [ Schema.DocRef::{
        , key = "getting-started"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "Install baikai, register providers, make your first blocking and streaming calls."
        , location = Schema.DocLocation.LocalFile "docs/user/getting-started.md"
        }
      , Schema.DocRef::{
        , key = "streaming"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "The AssistantMessageEvent algebra, fold patterns, and recovering partial output on failure."
        , location = Schema.DocLocation.LocalFile "docs/user/streaming.md"
        }
      , Schema.DocRef::{
        , key = "tools"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "Declaring tools, the ToolChoice options, and the two-turn round-trip pattern with appendToolResult."
        , location = Schema.DocLocation.LocalFile "docs/user/tools.md"
        }
      , Schema.DocRef::{
        , key = "models-and-providers"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "The generated catalog, hand-rolled Model records, the registry, and multi-host OpenAI-compat targets."
        , location =
            Schema.DocLocation.LocalFile "docs/user/models-and-providers.md"
        }
      , Schema.DocRef::{
        , key = "cli-providers"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "Driving claude -p and codex exec as subprocess providers: when to use them, configuration, response shape, and limitations."
        , location = Schema.DocLocation.LocalFile "docs/user/cli-providers.md"
        }
      , Schema.DocRef::{
        , key = "interactive-launches"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "Launching a local interactive agent CLI (Claude Code, Codex) that owns the terminal, tool loop, and session, versus the batch CLI providers."
        , location =
            Schema.DocLocation.LocalFile "docs/user/interactive-launches.md"
        }
      , Schema.DocRef::{
        , key = "agent-assets"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "Baikai.AgentAssets: pure provider-native path rules for local agent assets like skills and custom agents."
        , location = Schema.DocLocation.LocalFile "docs/user/agent-assets.md"
        }
      , Schema.DocRef::{
        , key = "kit"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "baikai-kit: the shared installer lifecycle for git-hosted kits of agent skills and subagents — clone/update, manifest parsing, install/uninstall, status, and session directories."
        , location = Schema.DocLocation.LocalFile "docs/user/kit.md"
        }
      , Schema.DocRef::{
        , key = "prompt-caching"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "The CacheRetention preference, host-aware long/short downgrade, and reading the cache read/write token and cost split back from Usage."
        , location = Schema.DocLocation.LocalFile "docs/user/prompt-caching.md"
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "mori/improvement-requests-profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Baikai-owned improvement requests"
        }
      ]
    }
