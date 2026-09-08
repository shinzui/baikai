-- Turn an observed release tag into the one immutable Project release fact
-- mori keeps for shinzui/baikai.
--
-- Registered as its own named automation (`--name release`) rather than merged
-- with automation/announce.dhall, because the two want opposite execution
-- policies and a directory of .dhall files must agree on every scalar policy.
-- This one shells out once per observed tag and has to serialize; announcing
-- must not queue behind a recording.
--
-- Pinned to mori-schema 7904371, the commit that adds `RefSelector.refRegexes`.
-- This is the commit the current mori binary embeds, so the import resolves
-- without touching the network.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/7904371c3ee1f592b427167e213cb1baa835de2c/package.dhall
        sha256:4b3730d985a19575278e3f155d98d5a60992e5f51b4f9223d390ef13e513e3c4

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.RefSelector Schema.RefSelector::{
        , name = "baikai-release-tag"
        ,
          -- Only the umbrella `baikai-<version>` tag, not the six sibling
          -- package tags. A whole-input POSIX extended regex, so
          -- `baikai-0.6.0.1` matches and `baikai-agent-0.2.0.0` does not. Ref
          -- globs understand `*` and `**` and nothing else, so before mori grew
          -- `refRegexes` this narrowing had to live in
          -- scripts/record-release.sh, which fired on all seven tags and exited
          -- quietly on six. `[.]` for the literal dot: a Dhall double-quoted
          -- string would otherwise need the backslash doubled.
          refRegexes = [ "baikai-[0-9]+([.][0-9]+)*" ]
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
              -- Not the 600-second default, which would hold the FIFO group for
              -- ten minutes on a hung database -- but not the 60 seconds this
              -- used to be either. Every RunCommand is executed as
              -- `nix develop --command`, and that entry, not the single
              -- `mori registry release record` against a local Postgres,
              -- dominates: three reactions timed out here at 60s on 2026-08-30
              -- while the nix eval cache was cold and contended, which is how
              -- the 0.6.0.1 release fact went unrecorded.
              timeout = Some +300
            }
          ]
        }
      ]
    ,
      -- A release cut now triggers this once, not seven times, so the original
      -- reason for queueing is gone. It is kept for the replay case:
      -- `mori automate reset-checkpoint --to-root` re-observes every umbrella
      -- tag in the repo's history at once, and serializing keeps those
      -- invocations from racing each other into the same Project stream.
      -- Re-recording a version is already safe -- the first committed release
      -- time and source win -- so this is about avoiding contention, not
      -- correctness.
      queued = True
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
