# git-hooks.nix (pre-commit) as a flake-parts module. The dev shell installs the
# hooks via `config.pre-commit.installationScript` (see ./haskell.nix). The old
# flake defined no custom hooks, so only treefmt is wired here.
{ inputs, ... }:
{
  imports = [ inputs.pre-commit-hooks.flakeModule ];

  perSystem = { config, pkgs, ... }: {
    pre-commit.settings.hooks = {
      treefmt = {
        enable = true;
        package = config.treefmt.build.wrapper;

        # Baikai.Models.Generated is emitted verbatim by baikai-gen-models and
        # guarded by a byte-identity round-trip test (CatalogSpec). treefmt.nix
        # already lists it in `settings.global.excludes`, but treefmt only
        # honors that when it *traverses* the tree (e.g. `nix fmt`). The
        # pre-commit hook passes staged filenames explicitly, and treefmt
        # formats explicitly-named files regardless of `excludes` — so without
        # this the hook rewrites the generated file to fourmolu's trailing-comma
        # layout and breaks the round-trip test. Exclude it at the hook level so
        # pre-commit never hands it to treefmt, letting a regenerated
        # Generated.hs be committed without `--no-verify`.
        excludes = [ "^baikai/src/Baikai/Models/Generated\\.hs$" ];
      };
    };
  };
}
