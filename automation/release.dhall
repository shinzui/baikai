-- Turn an observed release tag into the one immutable Project release fact
-- mori keeps for shinzui/baikai.
--
-- Registered as its own named automation (`--name release`) rather than merged
-- with automation/announce.dhall, because the two want opposite execution
-- policies and a directory of .dhall files must agree on every scalar policy.
-- This one shells out once per observed tag and has to serialize; announcing
-- must not queue behind a recording.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9899d4544790da7120e8150c73e56cb53fe35191/package.dhall
        sha256:4024df757a0178e37fb0b5f04d7deb284dc3ee9bfea89a6610b793338101e284

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.RefSelector Schema.RefSelector::{
        , name = "baikai-release-tag"
        ,
          -- Every release tag in the repo, not only the umbrella one. Mori's
          -- ref globs understand `*` and `**` and nothing else, so no pattern
          -- can say "baikai- followed by a version and no further package
          -- segment". scripts/record-release.sh makes that distinction and
          -- exits quietly on the six sibling package tags.
          refPatterns = [ "baikai-*" ]
        , kinds = [ "tag" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "record-baikai-release"
        , on = [ "baikai-release-tag" ]
        , actions =
          [ Schema.ReactionAction.RunCommand Schema.RunCommandAction::{
            , command = "./scripts/record-release.sh"
            , args = [ "{{ref.name}}" ]
            ,
              -- The script is one `mori registry release record` call against
              -- a local Postgres. A minute is already generous; without an
              -- explicit value this would inherit the 600-second default and
              -- hold the FIFO group for ten minutes on a hung database.
              timeout = Some +60
            }
          ]
        }
      ]
    ,
      -- One release cut pushes seven tags in the same second, so this
      -- automation is triggered seven times at once. Recording a version twice
      -- is already safe -- the first committed release time and source win --
      -- but serializing keeps the seven `mori` invocations from racing each
      -- other into the same Project stream.
      queued = True
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
