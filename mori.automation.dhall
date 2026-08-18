let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/a3c59033a08c2eaef2cfba4a3c99fc9c192ca6d7/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.RefSelector Schema.RefSelector::{
        , name = "baikai-release-tag"
        ,
          -- Deliberately every release tag in this repo, not just the packages
          -- a given consumer depends on. A release pushes one tag per package,
          -- so this fires several times for one release; the consumer debounces
          -- with a coalesceKey and then re-derives what it actually needs from
          -- Hackage. Matching broadly and letting the consumer decide keeps this
          -- selector from having to know any consumer's dependency list, and
          -- keeps it correct when baikai leaves the 0.x series.
          refPatterns = [ "baikai-*" ]
        , kinds = [ "tag" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "announce-baikai-release"
        , on = [ "baikai-release-tag" ]
        , actions =
          [ Schema.ReactionAction.Signal Schema.SignalAction::{
            , signalType = "BaikaiReleased"
            , targets = [ "shinzui/kioku" ]
            , payload =
              [ { mapKey = "tag", mapValue = "{{ref.name}}" }
              , { mapKey = "commit", mapValue = "{{ref.target}}" }
              ]
            }
          ]
        }
      ]
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
