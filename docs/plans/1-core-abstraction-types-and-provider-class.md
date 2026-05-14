---
id: 1
slug: core-abstraction-types-and-provider-class
title: "Core abstraction types and Provider class"
kind: exec-plan
created_at: 2026-05-13T23:39:17Z
intention: "intention_01krhv5e3ge8gbtm77v3qjvbb9"
master_plan: "docs/masterplans/1-ai-provider-abstraction-library.md"
---

# Core abstraction types and Provider class

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This ExecPlan establishes the type-level foundation of the `baikai` library:
a `Provider` typeclass, an existential `SomeProvider` wrapper, and the
request / response / usage / cost / error data types every later plan
(EP-2 Anthropic, EP-3 OpenAI, EP-4 Claude CLI, EP-5 tracing wrapper) will
consume unchanged. There are no provider implementations here — only the
shared vocabulary the rest of the project will speak.

After this plan lands, `cabal build all` compiles the library with the new
modules and `cabal test all` runs a new `baikai-test` suite that constructs
a `Request`, dispatches it through an in-test `TestProvider`, and
pattern-matches the resulting `Response` to confirm both that typeclass
dispatch works and that the `_Request` smart default produces the expected
zero values.

The public `Baikai` module — currently a stub exposing a single `greet`
function — is replaced by a re-export module surfacing every new type and
the `Provider` class. After this plan, `import Baikai` is enough for a
downstream consumer to write a `Provider` instance. The user-visible
behavior is not yet "talk to an LLM"; it is "the library compiles, the test
suite passes, and the `Provider` abstraction is ready for the first real
backend to slot into in EP-2."


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-05-13 Create `baikai/src/Baikai/Model.hs` with `Model` newtype and JSON / `IsString` instances.
- [x] 2026-05-13 Create `baikai/src/Baikai/Message.hs` with `Role`, `Message`, and the `user` / `assistant` / `system` smart constructors.
- [x] 2026-05-13 Create `baikai/src/Baikai/Usage.hs` with `Usage` record and JSON instances (snake_case).
- [x] 2026-05-13 Create `baikai/src/Baikai/Cost.hs` with `Cost`, `CostBreakdown`, and the `usdAsScientific` helper.
- [x] 2026-05-13 Create `baikai/src/Baikai/Error.hs` with `BaikaiError` and its `Exception` instance.
- [x] 2026-05-13 Create `baikai/src/Baikai/Request.hs` with `Request` record and the `_Request` default.
- [x] 2026-05-13 Create `baikai/src/Baikai/Response.hs` with `Response` record.
- [x] 2026-05-13 Create `baikai/src/Baikai/Provider.hs` with the `Provider` typeclass, `SomeProvider`, and `runSome`.
- [x] 2026-05-13 Update `baikai/baikai.cabal` `exposed-modules` and add `aeson`, `bytestring`, `containers`, `scientific`, `time`, `vector` to `build-depends`. M1 `cabal build all` clean.
- [x] 2026-05-13 Extend `baikai/src/Baikai/Prelude.hs` to re-export `MonadIO`, `Text`, `Vector`, `Natural`, `Generic`, and the aeson surface. `liftIO` is reached via `MonadIO(..)` to avoid a `-Wduplicate-exports` warning.
- [x] 2026-05-13 Replace the stub in `baikai/src/Baikai.hs` with the public re-export module.
- [x] 2026-05-13 Add a `test-suite baikai-test` stanza to `baikai/baikai.cabal`.
- [x] 2026-05-13 Create `baikai/test/Main.hs` with a `TestProvider` instance and three tasty/HUnit tests.
- [x] 2026-05-13 `cabal build all` succeeds inside `nix develop`.
- [x] 2026-05-13 `cabal test all` reports `All 3 tests passed` inside `nix develop`.
- [x] 2026-05-13 Validation criterion (3): `cabal repl baikai` REPL session defines a local `TP` `Provider` and dispatches `runRequest TP …` → `"ok"`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-05-13: `Baikai.Prelude`'s initial draft listed both `MonadIO (..)` and `liftIO` in the export list. GHC 9.12.2 emits `-Wduplicate-exports` ("'liftIO' is exported by 'liftIO' and 'MonadIO(..)'") because `liftIO` is a class method already covered by `MonadIO (..)`. Resolved by dropping the standalone `liftIO` export and the corresponding import; `import Baikai.Prelude` still puts `liftIO` in scope via the `MonadIO` class method export.


## Decision Log

Record every decision made while working on the plan.

- Decision: `Model` is a `newtype Model = Model {unModel :: Text}`, not an
  enumeration.
  Rationale: Providers release new model identifiers (`claude-sonnet-4-5-...`,
  `gpt-4o-...`) far faster than a library can cut releases. A `Text` wrapper
  passes through any identifier while still distinguishing model strings from
  arbitrary text at the type level.
  Date: 2026-05-13

- Decision: `Usage` normalizes to `inputTokens` / `outputTokens` plus
  `Maybe`-wrapped `cachedInputTokens` and `reasoningTokens`.
  Rationale: All providers report input/output; only some report cache hits
  (Anthropic, OpenAI) or reasoning tokens (o-series, extended thinking). `Maybe`
  preserves the "not reported" signal instead of silently encoding it as zero.
  Date: 2026-05-13

- Decision: `Cost.usd` is `Rational`, not `Double`.
  Rationale: Pricing is published as USD per million tokens. Accumulating
  large-batch costs in `Double` drifts. `Rational` preserves the exact ratio;
  `usdAsScientific` converts only for display.
  Date: 2026-05-13

- Decision: `Provider` is both a typeclass and an existential
  (`SomeProvider`).
  Rationale: The class gives static dispatch when the provider type is known.
  The existential gives runtime polymorphism so configuration code can build a
  heterogeneous list (for example a fallback chain) without leaking each
  implementation's type into every signature.
  Date: 2026-05-13

- Decision: EP-1 ships no provider implementations (Anthropic in EP-2,
  OpenAI in EP-3, Claude CLI in EP-4, tracing wrapper in EP-5).
  Rationale: Keeping EP-1 focused on the abstraction means later plans review
  in isolation against a stable contract, and a regression in any one backend
  cannot block the others from compiling.
  Date: 2026-05-13

- Decision: `Provider.runRequest` is `MonadIO m =>`, not concrete `IO`.
  Rationale: Forward-compat with a future `baikai-effectful` package whose providers will run inside `Eff es`. `Eff es` is a `MonadIO` whenever `IOE :> es`, so any provider written today against `MonadIO m` works in effectful without changes. Bracket/fork entry points are not affected here (none in EP-1), but the same rationale will be applied selectively elsewhere — bracket signatures stay in `IO` because `Eff es` is not a `MonadUnliftIO`.
  Date: 2026-05-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-05-13: EP-1 complete. All three milestones landed across three
  commits on `master`. The `baikai` package now exposes `Model`,
  `Message`, `Usage`, `Cost`, `CostBreakdown`, `BaikaiError`,
  `Request`, `Response`, the `Provider` typeclass, the
  `SomeProvider` existential, and `runSome` — the entire vocabulary
  EP-2 through EP-6 will consume.
- `cabal build all` builds the library cleanly with no warnings.
  `cabal test all` runs `baikai-test` and reports
  `All 3 tests passed`. The REPL transcript in
  `Validation and Acceptance` (criterion 3) was executed verbatim and
  `runRequest TP …` returned `"ok"`, confirming that the typeclass,
  the existential, the records, the lens-based field access, and the
  smart defaults all work together.
- One deviation from the written plan: `Baikai.Prelude` lists
  `MonadIO (..)` but not a standalone `liftIO` export. GHC 9.12.2
  flags the redundant pair with `-Wduplicate-exports` because `liftIO`
  is already a class method covered by `MonadIO (..)`. Recorded in
  Surprises & Discoveries. Downstream consumers still get `liftIO`
  from `import Baikai.Prelude`.
- No surprises in the type-level design: `Rational` cost, `Maybe`
  usage fields, and the `Text`-typed `Model` field all compiled
  without back-and-forth and gave the test suite an unsurprising
  shape. EP-2 can begin immediately and is unblocked.


## Context and Orientation

The project root is `/Users/shinzui/Keikaku/bokuno/baikai`. It contains a
single cabal package at `baikai/`:
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/baikai.cabal` with library
source under `baikai/src/`. There is no test suite yet — this plan adds
the first one.

The cabal package targets `GHC2024` as `default-language`. The
`common-options` stanza enables the standard warning set (including
`-Wmissing-export-lists` and `-Wmissing-deriving-strategies`) and four
default extensions: `DeriveAnyClass`, `DuplicateRecordFields`,
`OverloadedLabels`, `OverloadedStrings`. Any module needing a non-default
extension (for example `ExistentialQuantification` for `SomeProvider`)
declares it with a `{-# LANGUAGE ... #-}` pragma in the file. Because
`-Wmissing-deriving-strategies` is on, every `deriving` clause must name
`stock`, `anyclass`, or `newtype`.

Existing library `build-depends` are `base >=4.20 && <5`, `generic-lens`,
`lens ^>=5.3`, `text ^>=2.1`. This plan adds `aeson`, `bytestring`,
`containers`, `time`, `vector`, `scientific`. (`bytestring`, `containers`,
`time` are not strictly needed by EP-1 but adding them now means EP-2+ do
not have to touch `build-depends` for trivially expected libraries.)

The build is driven by `nix develop` at the project root, which provides
`ghc-9.12` and `cabal-install`. `cabal build all` and `cabal test all`
are the canonical commands.

Existing modules:

- `baikai/src/Baikai.hs` — a stub exporting only `greet :: Text -> Text`.
  This plan replaces its contents entirely with a re-export module.
- `baikai/src/Baikai/Prelude.hs` — the project-wide Prelude, reproduced
  below verbatim so this plan is self-contained:

```haskell
module Baikai.Prelude
  ( -- * Lens vocabulary
    module Control.Lens

    -- * Generic-lens vocabulary
  , module Data.Generics.Product
  , module Data.Generics.Sum
  ) where

import Control.Lens
import Data.Generics.Labels ()
import Data.Generics.Product
import Data.Generics.Sum
```

This plan extends — does not rewrite — `Baikai.Prelude` to also re-export
`Data.Text.Text`, `Data.Vector.Vector`, `Numeric.Natural.Natural`,
`GHC.Generics.Generic`, and the aeson surface (`FromJSON`, `ToJSON`,
`genericParseJSON`, `genericToJSON`).

Two convention documents govern the new modules:

- `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md` —
  strict fields with leading `!`, no type-prefixed field names (`role`,
  not `messageRole`), all access via lens (`record ^. #field`,
  `record & #field .~ value`). No Haskell record-update syntax. Smart
  defaults are named with a leading underscore (`_Request`, `_Usage`).
- `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/custom-prelude.md` —
  the import-and-re-export pattern used by `Baikai.Prelude`.

Fourmolu config at `baikai/fourmolu.yaml`: 2-space indent, trailing
function arrows, trailing import / export commas, trailing list commas.


## Plan of Work

Three milestones. M1 introduces the data types and the `Provider`
typeclass; the library compiles but `import Baikai` still exposes only the
old `greet`. M2 rewrites `Baikai` and extends `Baikai.Prelude` so the new
surface is public. M3 adds the test suite. M1 / M2 are verified by
`cabal build all`; M3 by `cabal test all`.


### Milestone 1: Types and Provider class

Create every new module under `baikai/src/Baikai/` in dependency order, then
update `baikai.cabal`'s `exposed-modules` and `build-depends`.

#### `Baikai.Model` — file `baikai/src/Baikai/Model.hs`

```haskell
module Baikai.Model (Model (..)) where

import Data.Aeson (FromJSON, ToJSON)
import Data.String (IsString)
import Data.Text (Text)
import GHC.Generics (Generic)

newtype Model = Model {unModel :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString, FromJSON, ToJSON)
```

`IsString` + `OverloadedStrings` lets callers write
`"claude-sonnet-4-5-20250929" :: Model`. The newtype JSON instances make a
`Model` round-trip as a bare JSON string.

#### `Baikai.Message` — file `baikai/src/Baikai/Message.hs`

EP-1 supports plain-text content only; multi-part content (images, tool
results) is deferred.

```haskell
module Baikai.Message
  ( Role (..)
  , Message (..)
  , user
  , assistant
  , system
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

data Role = User | Assistant | System
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Message = Message
  { role :: !Role
  , content :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

user, assistant, system :: Text -> Message
user      t = Message {role = User,      content = t}
assistant t = Message {role = Assistant, content = t}
system    t = Message {role = System,    content = t}
```

#### `Baikai.Usage` — file `baikai/src/Baikai/Usage.hs`

Token counters; `cachedInputTokens` and `reasoningTokens` are `Maybe` because
not every provider reports them. JSON field names are snake_case to match
the provider conventions both Anthropic and OpenAI use.

```haskell
module Baikai.Usage (Usage (..), _Usage) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , Options (fieldLabelModifier)
  , ToJSON (toJSON)
  , camelTo2
  , defaultOptions
  , genericParseJSON
  , genericToJSON
  )
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data Usage = Usage
  { inputTokens :: !Natural
  , outputTokens :: !Natural
  , cachedInputTokens :: !(Maybe Natural)
  , reasoningTokens :: !(Maybe Natural)
  }
  deriving stock (Eq, Show, Generic)

usageOptions :: Options
usageOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

instance FromJSON Usage where parseJSON = genericParseJSON usageOptions
instance ToJSON   Usage where toJSON    = genericToJSON   usageOptions

_Usage :: Usage
_Usage = Usage
  { inputTokens = 0
  , outputTokens = 0
  , cachedInputTokens = Nothing
  , reasoningTokens = Nothing
  }
```

`camelTo2 '_'` from `Data.Aeson` is used directly, avoiding a dependency on
`aeson-casing`.

#### `Baikai.Cost` — file `baikai/src/Baikai/Cost.hs`

`Rational` storage keeps USD-per-million-token arithmetic exact across large
batches. `usdAsScientific` converts only for display / serialization.
`FromJSON` is intentionally omitted in EP-1.

```haskell
module Baikai.Cost
  ( Cost (..)
  , CostBreakdown (..)
  , _Cost
  , _CostBreakdown
  , usdAsScientific
  ) where

import Data.Aeson (ToJSON (toJSON), object, (.=))
import Data.Scientific (Scientific, fromRationalRepetendUnlimited)
import GHC.Generics (Generic)

data CostBreakdown = CostBreakdown
  { inputUsd :: !Rational
  , outputUsd :: !Rational
  , cachedInputUsd :: !Rational
  }
  deriving stock (Eq, Show, Generic)

data Cost = Cost
  { usd :: !Rational
  , breakdown :: !CostBreakdown
  }
  deriving stock (Eq, Show, Generic)

_CostBreakdown :: CostBreakdown
_CostBreakdown = CostBreakdown {inputUsd = 0, outputUsd = 0, cachedInputUsd = 0}

_Cost :: Cost
_Cost = Cost {usd = 0, breakdown = _CostBreakdown}

instance ToJSON CostBreakdown where
  toJSON cb =
    object
      [ "input_usd"        .= ratToSci (inputUsd cb)
      , "output_usd"       .= ratToSci (outputUsd cb)
      , "cached_input_usd" .= ratToSci (cachedInputUsd cb)
      ]

instance ToJSON Cost where
  toJSON c =
    object
      [ "usd"       .= ratToSci (usd c)
      , "breakdown" .= breakdown c
      ]

usdAsScientific :: Cost -> Scientific
usdAsScientific = ratToSci . usd

ratToSci :: Rational -> Scientific
ratToSci = fst . fromRationalRepetendUnlimited
```

#### `Baikai.Error` — file `baikai/src/Baikai/Error.hs`

```haskell
module Baikai.Error (BaikaiError (..)) where

import Control.Exception (Exception)
import Data.Text (Text)
import GHC.Generics (Generic)

data BaikaiError
  = ProviderError  !Text         -- ^ HTTP 4xx/5xx or CLI nonzero
  | RequestInvalid !Text         -- ^ local validation failed
  | DecodeError    !Text         -- ^ payload could not be decoded
  | ProcessError   !Int !Text    -- ^ subprocess failed (exit code + stderr)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Exception)
```

#### `Baikai.Request` — file `baikai/src/Baikai/Request.hs`

Construct via lens starting from `_Request`. No JSON instances here —
encoding shape differs per provider (Anthropic's `system` vs OpenAI's
first-message-with-role-system) and lives in each provider module.

```haskell
module Baikai.Request (Request (..), _Request) where

import Baikai.Message (Message)
import Baikai.Model (Model (..))
import Data.Text (Text)
import Data.Vector (Vector)
import qualified Data.Vector as V
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data Request = Request
  { model :: !Model
  , messages :: !(Vector Message)
  , maxTokens :: !Natural
  , temperature :: !(Maybe Double)
  , systemPrompt :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

_Request :: Request
_Request = Request
  { model = Model ""
  , messages = V.empty
  , maxTokens = 1024
  , temperature = Nothing
  , systemPrompt = Nothing
  }
```

#### `Baikai.Response` — file `baikai/src/Baikai/Response.hs`

`latencyMs` is populated by the tracing wrapper (EP-5); the field exists
from day one so the `Response` type is stable.

```haskell
module Baikai.Response (Response (..), _Response) where

import Baikai.Cost (Cost)
import Baikai.Model (Model (..))
import Baikai.Usage (Usage)
import Data.Text (Text)
import GHC.Generics (Generic)

data Response = Response
  { content :: !Text
  , model :: !Model
  , usage :: !(Maybe Usage)
  , cost :: !(Maybe Cost)
  , provider :: !Text
  , latencyMs :: !Integer
  }
  deriving stock (Eq, Show, Generic)

_Response :: Response
_Response = Response
  { content = ""
  , model = Model ""
  , usage = Nothing
  , cost = Nothing
  , provider = ""
  , latencyMs = 0
  }
```

#### `Baikai.Provider` — file `baikai/src/Baikai/Provider.hs`

`ExistentialQuantification` is not implied by `GHC2024`; declare it as a
pragma at the top of the file.

```haskell
{-# LANGUAGE ExistentialQuantification #-}

module Baikai.Provider
  ( Provider (..)
  , SomeProvider (..)
  , runSome
  ) where

import Baikai.Request (Request)
import Baikai.Response (Response)
import Control.Monad.IO.Class (MonadIO)
import Data.Text (Text)

class Provider p where
  providerName :: p -> Text
  runRequest   :: MonadIO m => p -> Request -> m Response

data SomeProvider = forall p. (Provider p) => SomeProvider p

runSome :: MonadIO m => SomeProvider -> Request -> m Response
runSome (SomeProvider p) = runRequest p
```

`Control.Monad.IO.Class` is re-exported from `Baikai.Prelude` (see
Milestone 2), so user-written `Provider` instances importing
`Baikai.Prelude` get `MonadIO` and `liftIO` for free. The
`import Control.Monad.IO.Class (MonadIO)` line above is local to
`Baikai.Provider.hs` because that module does not itself import
`Baikai.Prelude`.

#### Cabal updates for M1 — `baikai/baikai.cabal`

The test stanza comes in M3; this diff covers modules + deps.

```diff
   library
     import: common-options
     hs-source-dirs: src
     exposed-modules:
       Baikai
       Baikai.Prelude
+      Baikai.Cost
+      Baikai.Error
+      Baikai.Message
+      Baikai.Model
+      Baikai.Provider
+      Baikai.Request
+      Baikai.Response
+      Baikai.Usage

     build-depends:
       base >=4.20 && <5,
+      aeson,
+      bytestring,
+      containers,
       generic-lens,
       lens ^>=5.3,
+      scientific,
       text ^>=2.1,
+      time,
+      vector,
```

Acceptance for Milestone 1: `cabal build all` succeeds. (`Baikai` still
exports only `greet`; that is intentional — it changes in Milestone 2.)


### Milestone 2: Public surface and Prelude

Extend `Baikai.Prelude` and rewrite `Baikai` to re-export the new modules.
After this milestone, `import Baikai` is the only import a downstream
consumer needs to write a `Provider` instance.

#### Updated `Baikai.Prelude` — file `baikai/src/Baikai/Prelude.hs`

```haskell
module Baikai.Prelude
  ( -- * Lens vocabulary
    module Control.Lens
    -- * Generic-lens vocabulary
  , module Data.Generics.Product
  , module Data.Generics.Sum
    -- * IO lifting (`liftIO` re-exported as a method of `MonadIO`)
  , MonadIO (..)
    -- * Scalar types
  , Text
  , Vector
  , Natural
    -- * Generics
  , Generic
    -- * JSON
  , FromJSON (..)
  , ToJSON (..)
  , genericParseJSON
  , genericToJSON
  ) where

import Control.Lens
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Generics.Labels ()
import Data.Generics.Product
import Data.Generics.Sum
import Data.Text (Text)
import Data.Vector (Vector)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
```

`liftIO` is re-exported as a method of the `MonadIO` class; listing it as
a standalone export alongside `MonadIO (..)` would trigger
`-Wduplicate-exports` on GHC 9.12.

Downstream consumers writing a `Provider` instance get `MonadIO` and
`liftIO` via `import Baikai.Prelude` and do not need a separate
`import Control.Monad.IO.Class`.

#### Rewritten `Baikai` — file `baikai/src/Baikai.hs`

The stub `greet` is removed entirely.

```haskell
module Baikai
  ( -- * Types
    module Baikai.Model
  , module Baikai.Message
  , module Baikai.Request
  , module Baikai.Response
  , module Baikai.Usage
  , module Baikai.Cost
  , module Baikai.Error
    -- * Provider abstraction
  , module Baikai.Provider
  ) where

import Baikai.Cost
import Baikai.Error
import Baikai.Message
import Baikai.Model
import Baikai.Provider
import Baikai.Request
import Baikai.Response
import Baikai.Usage
```

Acceptance for M2: `cabal build all` succeeds; `cabal repl baikai`
followed by `import Baikai` exposes `Request`, `Response`, `Provider`,
`runRequest`, `_Request`, etc. without further imports.


### Milestone 3: Test suite

Add a `test-suite` stanza to `baikai.cabal` and create
`baikai/test/Main.hs`.

```diff
+test-suite baikai-test
+  import: common-options
+  type: exitcode-stdio-1.0
+  hs-source-dirs: test
+  main-is: Main.hs
+  build-depends:
+    base,
+    baikai,
+    tasty,
+    tasty-hunit,
+    text,
+    vector,
```

`tasty` / `tasty-hunit` get no upper bound — nix pins the toolchain.

File `baikai/test/Main.hs`. The test imports `Baikai.Prelude` for `^.`,
`&`, `.~`, and the `#field` labels.

```haskell
module Main (main) where

import Baikai
import Baikai.Prelude
import qualified Data.Vector as V
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

data TestProvider = TestProvider {cannedContent :: !Text}

instance Provider TestProvider where
  providerName _ = "test"
  runRequest TestProvider{ cannedContent } _ =
    pure Response
      { content = cannedContent
      , model = Model "test"
      , usage = Nothing
      , cost = Nothing
      , provider = "test"
      , latencyMs = 0
      }

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "baikai EP-1"
  [ testCase "_Request defaults are zero-y" $ do
      unModel (_Request ^. #model)     @?= ""
      V.length (_Request ^. #messages) @?= 0
      _Request ^. #maxTokens           @?= 1024
      _Request ^. #temperature         @?= Nothing
      _Request ^. #systemPrompt        @?= Nothing
  , testCase "TestProvider returns the canned content" $ do
      let req = _Request
                  & #model    .~ Model "test-model"
                  & #messages .~ V.fromList [user "ping"]
          provider = TestProvider {cannedContent = "hello from the test provider"}
      resp <- runRequest provider req :: IO Response
      resp ^. #content              @?= "hello from the test provider"
      unModel (resp ^. #model)      @?= "test"
      resp ^. #provider             @?= "test"
  , testCase "SomeProvider wraps and dispatches" $ do
      let provider = TestProvider {cannedContent = "hello from the test provider"}
      resp <- runSome (SomeProvider provider) _Request :: IO Response
      resp ^. #content @?= "hello from the test provider"
  ]
```

The `runRequest` body is just `pure`, which is polymorphic in `Monad`,
and a fortiori in `MonadIO m`. The call sites annotate the result as
`IO Response`, which is enough to fix `m ~ IO`; the `MonadIO IO`
instance discharges the constraint, so no `liftIO` is needed at either
the definition or the call site.

Acceptance for M3: `cabal test all` reports `All 3 tests passed`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/baikai`.

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
nix develop
cabal build all   # baseline check before any edits
```

Then implement Milestone 1 (the eight new modules and the `build-depends`
+ `exposed-modules` update). The build will fail until all eight modules
exist; re-run after each file. Final M1 build:

```text
Building library for baikai-0.1.0.0...
[1 of 10] Compiling Baikai.Prelude   ...
[2 of 10] Compiling Baikai.Model     ...
[3 of 10] Compiling Baikai.Message   ...
[4 of 10] Compiling Baikai.Usage     ...
[5 of 10] Compiling Baikai.Cost      ...
[6 of 10] Compiling Baikai.Error     ...
[7 of 10] Compiling Baikai.Request   ...
[8 of 10] Compiling Baikai.Response  ...
[9 of 10] Compiling Baikai.Provider  ...
[10 of 10] Compiling Baikai          ...
```

Implement Milestone 2 (rewrite `Baikai.hs`, extend `Baikai/Prelude.hs`)
and re-run `cabal build all`. Then implement Milestone 3 (test-suite
stanza + `baikai/test/Main.hs`) and run:

```bash
cabal test all
```

Expected:

```text
baikai EP-1
  _Request defaults are zero-y:             OK
  TestProvider returns the canned content:  OK
  SomeProvider wraps and dispatches:        OK

All 3 tests passed (0.00s)
```

Smoke-check the REPL surface:

```bash
cabal repl baikai
```

```text
ghci> import Baikai
ghci> import Baikai.Prelude
ghci> import qualified Data.Vector as V
ghci> let r = _Request & #model .~ Model "demo" & #messages .~ V.fromList [user "hi"]
ghci> unModel (r ^. #model)
"demo"
ghci> r ^. #maxTokens
1024
```


## Validation and Acceptance

EP-1 is complete when all three of the following hold simultaneously.

(1) `cabal build all` succeeds from inside `nix develop` at
`/Users/shinzui/Keikaku/bokuno/baikai`, with no warnings other than those
present on the unchanged baseline.

(2) `cabal test all` runs the new `baikai-test` suite and reports all three
test cases (`_Request defaults are zero-y`, `TestProvider returns the canned
content`, `SomeProvider wraps and dispatches`) passing, with the final
`All 3 tests passed` line.

(3) A `cabal repl baikai` session can construct a `Request`, define a local
`Provider` instance, dispatch the request through `runRequest`, and read the
resulting `Response`'s `content`. Reproducible verbatim:

```text
ghci> :set -XOverloadedStrings -XOverloadedLabels
ghci> import Baikai
ghci> import Baikai.Prelude
ghci> :{
ghci| data TP = TP
ghci| instance Provider TP where
ghci|   providerName _ = "tp"
ghci|   runRequest _ _ = pure (_Response & #content .~ "ok")
ghci| :}
ghci> resp <- runRequest TP (_Request & #model .~ Model "x")
ghci> resp ^. #content
"ok"
```

The third criterion is the strongest: it demonstrates that the typeclass,
the existential, the records, the lens-based field access, and the smart
defaults all work together — not just that a single test file passes.


## Idempotence and Recovery

Every edit is additive. The only file whose contents are replaced wholesale
is `baikai/src/Baikai.hs` — the existing `greet` function is removed because
the module becomes a pure re-export module. If the rewrite of `Baikai.hs` is
interrupted, `git checkout HEAD -- baikai/src/Baikai.hs` restores the original
stub and returns the package to a buildable baseline.

`cabal build all` and `cabal test all` are themselves idempotent. The build
cache in `dist-newstyle/` is the only persistent state; `cabal clean`
discards it if a stale cache produces confusing errors (rare, but possible
after an extension or default-language change).

If `cabal test all` fails after the plan is implemented, the two most likely
causes are:

1. A new module is missing from `exposed-modules` in `baikai.cabal`. The
   compiler error reads `Could not find module 'Baikai.Foo'`. Fix by adding
   the module to the library stanza.
2. `OverloadedLabels` is not enabled in `baikai/test/Main.hs`. The default
   extension is set in the cabal `common-options` and inherited by the
   `test-suite` via `import: common-options`. If that `import:` line is
   missing, labels like `#content` will not parse. Fix by adding
   `import: common-options` to the `test-suite` stanza.

Neither failure mode corrupts source; both are recovered by an edit plus
`cabal build all`.


## Interfaces and Dependencies

### Libraries added to `baikai.cabal`

- `aeson` — JSON encoding / decoding for `Model`, `Message`, `Usage`, and
  the `ToJSON` instances of `Cost` / `CostBreakdown`.
- `bytestring` — pulled in now (not used in EP-1) so later provider plans
  can decode HTTP bodies without touching `build-depends`.
- `containers` — pulled in now for the same reason; later plans need `Map`
  for response-header parsing and prompt-cache state.
- `time` — pulled in now; the tracing wrapper in EP-5 needs `UTCTime` for
  log timestamps.
- `vector` — backs the `messages` field of `Request`. Chosen over `[]`
  because chat histories are read more often than they are appended to.
- `scientific` — backs `usdAsScientific`; `Scientific` is the standard
  serializable approximation of a `Rational`.
- `tasty`, `tasty-hunit` (test-only) — drive the new test suite.

### Module-level exports introduced by this plan

The signatures below define the contract that EP-2 through EP-5 import.
Any change to them after EP-1 lands is a breaking change.

```haskell
-- Baikai.Model
newtype Model = Model {unModel :: Text}
  -- Eq, Ord, Show, Generic, IsString, FromJSON, ToJSON

-- Baikai.Message
data Role = User | Assistant | System
  -- Eq, Show, Generic, FromJSON, ToJSON
data Message = Message {role :: !Role, content :: !Text}
  -- Eq, Show, Generic, FromJSON, ToJSON
user, assistant, system :: Text -> Message

-- Baikai.Usage
data Usage = Usage
  { inputTokens       :: !Natural
  , outputTokens      :: !Natural
  , cachedInputTokens :: !(Maybe Natural)
  , reasoningTokens   :: !(Maybe Natural)
  } -- Eq, Show, Generic, FromJSON, ToJSON
_Usage :: Usage

-- Baikai.Cost
data CostBreakdown = CostBreakdown
  { inputUsd       :: !Rational
  , outputUsd      :: !Rational
  , cachedInputUsd :: !Rational
  } -- Eq, Show, Generic, ToJSON
data Cost = Cost {usd :: !Rational, breakdown :: !CostBreakdown}
  -- Eq, Show, Generic, ToJSON
_Cost           :: Cost
_CostBreakdown  :: CostBreakdown
usdAsScientific :: Cost -> Scientific

-- Baikai.Error
data BaikaiError
  = ProviderError  !Text
  | RequestInvalid !Text
  | DecodeError    !Text
  | ProcessError   !Int !Text
  -- Eq, Show, Generic, Exception

-- Baikai.Request
data Request = Request
  { model        :: !Model
  , messages     :: !(Vector Message)
  , maxTokens    :: !Natural
  , temperature  :: !(Maybe Double)
  , systemPrompt :: !(Maybe Text)
  } -- Eq, Show, Generic
_Request :: Request  -- maxTokens=1024, everything else empty/Nothing

-- Baikai.Response
data Response = Response
  { content   :: !Text
  , model     :: !Model
  , usage     :: !(Maybe Usage)
  , cost      :: !(Maybe Cost)
  , provider  :: !Text
  , latencyMs :: !Integer
  } -- Eq, Show, Generic
_Response :: Response

-- Baikai.Provider
class Provider p where
  providerName :: p -> Text
  runRequest   :: MonadIO m => p -> Request -> m Response
data SomeProvider = forall p. Provider p => SomeProvider p
runSome :: MonadIO m => SomeProvider -> Request -> m Response

-- Baikai.Prelude (additions; existing lens / generic-lens exports preserved)
--   MonadIO (..), liftIO, Text, Vector, Natural, Generic,
--   FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON

-- Baikai: re-exports every module above. The old `greet` is removed.
```

`Control.Monad.IO.Class` (re-exported from `Baikai.Prelude`) supplies
`MonadIO` and `liftIO`. A user-written `Provider` instance whose body
is `pure …` or already lives in `IO` does not need any `liftIO`: the
constraint `MonadIO m => m Response` is satisfied at the call site
because `IO` is itself a `MonadIO`. Instances that wish to perform
arbitrary `IO` actions inside `runRequest` lift them with `liftIO`,
which is in scope from `Baikai.Prelude`.

### Downstream consumers

EP-2 (Anthropic provider), EP-3 (OpenAI provider), and EP-4 (Claude CLI
provider) each define a type with a `Provider` instance whose `runRequest`
serializes a `Request` to that provider's wire format and deserializes the
response into a `Response` (with `usage` and `cost` populated). EP-5
(tracing wrapper) defines a `newtype Traced p = Traced p` with a `Provider`
instance that delegates to the inner provider, measures wall-clock latency,
fills in `latencyMs`, and writes a trace event keyed off the `BaikaiError`
sum type. None of those plans modifies the signatures listed above.


## Revisions

- 2026-05-13: Generalised `Provider.runRequest` and `runSome` from concrete `IO` to `MonadIO m =>` to make a future `baikai-effectful` package possible without re-engineering the typeclass. Updated `Baikai.Prelude` to re-export `MonadIO` and `liftIO`. Driver: the MonadIO decision recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision Log on the same date.
