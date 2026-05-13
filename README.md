# baikai

> baikai provides a unified Haskell interface for working with multiple AI providers.

## Layout

This project is a single cabal package:

- **`baikai`** — the library. Exposes the top-level
  `Baikai` module (your public API surface) and a
  project-wide `Baikai.Prelude` that re-exports
  [`lens`](https://hackage.haskell.org/package/lens) and
  [`generic-lens`](https://hackage.haskell.org/package/generic-lens) so
  individual modules can `import Baikai.Prelude` and skip
  the usual per-module vocabulary imports.

The package targets **GHC `ghc912`** with `default-language: GHC2024`,
the standard warning set, and the default extensions `DeriveAnyClass`,
`DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings`.

## Develop

The project ships a Nix flake (`nix-haskell-flake`) that pins GHC and provides
the dev shell. Enter the shell with:

```bash
nix develop      # or: direnv allow, if you use direnv
```

Then build:

```bash
cabal build all
```

## License

[BSD-3-Clause](./LICENSE) — (c) 2026 Nadeem Bitar.
