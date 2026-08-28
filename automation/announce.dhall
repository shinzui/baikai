-- Tell downstream consumers that shinzui/baikai has released -- once per
-- release, rather than once per tag.
--
-- This replaces the tag-driven signal this repo emitted from
-- mori.automation.dhall until 0.6.0.0. That one fired seven times per release,
-- once per package tag, and left the consumer to debounce the burst and
-- re-derive the version from Hackage. Reacting to the Project release fact
-- instead yields one signal carrying the version mori actually recorded.
--
-- Registered as its own named automation (`--name announce`) so it keeps
-- `queued = False` while automation/release.dhall serializes: a signal
-- emission should not wait behind a `mori` subprocess.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9899d4544790da7120e8150c73e56cb53fe35191/package.dhall
        sha256:4024df757a0178e37fb0b5f04d7deb284dc3ee9bfea89a6610b793338101e284

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.ProjectSelector Schema.ProjectSelector::{
        , name = "baikai-release-fact"
        , aggregates = [ Schema.ProjectSignalAggregate.ProjectRoot ]
        , families = [ Schema.ProjectSignalFamily.Release ]
        ,
          -- Added only. Imported is already suppressed by the default
          -- includeImported = False, and naming Added keeps a future
          -- Updated or Removed release fact from being announced as a release.
          actions = [ Schema.ProjectSignalAction.Added ]
        ,
          -- Project facts are evaluated against every registered automation in
          -- the registry, not only against the project the fact is about.
          -- Without this the reaction would announce every other project's
          -- releases as baikai's.
          references = [ "mori://shinzui/baikai" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "announce-baikai-release"
        , on = [ "baikai-release-fact" ]
        , actions =
          [ Schema.ReactionAction.Signal Schema.SignalAction::{
            , signalType = "BaikaiReleased"
            ,
              -- Twelve projects depend on baikai; these two have a reaction
              -- that consumes BaikaiReleased. `*dependents*` would resolve all
              -- twelve, and a target with no registered automation dead-letters
              -- its delivery -- `mori doctor` still carries two such failures
              -- against shinzui/mori. Name the consumers, and add the next one
              -- when it has a reaction ready to receive this.
              --
              -- Both are named even though shikumi sits between baikai and
              -- kioku, because the edge is real in both cases: kioku depends on
              -- baikai directly, so a baikai patch its shikumi bounds already
              -- admit must reach it without waiting for a shikumi release.
              -- `mori workflow explain shinzui/baikai` renders the result.
              targets = [ "shinzui/shikumi", "shinzui/kioku" ]
            ,
              -- Assembled from the three release scalars rather than written
              -- as the whole-value `{{release.payloadJson}}` that mori's own
              -- `help trailer-matching` recommends. That form cannot load:
              -- validateSignalAction (mori-core/src/Mori/Automation/Load.hs)
              -- JSON-decodes this field when the config is read, which is
              -- before any template is expanded, so a bare placeholder always
              -- fails as malformed JSON. A document that is already valid JSON
              -- passes that gate and still interpolates at trigger time.
              --
              -- Keys are snake_case to match the release JSON mori emits
              -- elsewhere, so a consumer that later reads the whole-value form
              -- reads the same field names.
              payloadJson = Some
                ''
                { "version": "{{release.version}}"
                , "released_at": "{{release.releasedAt}}"
                , "source": "{{release.source}}"
                }
                ''
            }
          ]
        }
      ]
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
