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
        , dependencies =
          [ Schema.Dependency.ByName "shinzui/baikai:baikai" ]
        }
      , Schema.Package::{
        , name = "baikai-openai"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "baikai-openai"
        , description = Some
            "OpenAI providers (Chat Completions API and codex CLI) for the Baikai abstraction"
        , dependencies =
          [ Schema.Dependency.ByName "shinzui/baikai:baikai" ]
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
    }
