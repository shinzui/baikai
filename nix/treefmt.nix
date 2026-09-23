# treefmt-nix as a flake-parts module. This automatically wires `nix fmt`
# (the flake `formatter`) and a `treefmt` flake check. seihou-managed.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = { ... }: {
    treefmt = {
      projectRootFile = "flake.nix";

      # Baikai.Models.Generated is emitted verbatim by the baikai-gen-models
      # code generator (gen/GenModels.hs) and a round-trip test asserts the
      # committed file is byte-identical to that output. The generator emits
      # its own layout, so keep fourmolu's hands off it — otherwise formatting
      # and generation fight and the round-trip test fails.
      settings.global.excludes = [ "baikai/src/Baikai/Models/Generated.hs" ];

      programs.nixpkgs-fmt.enable = true;
      programs.fourmolu.enable = true;
      # cabal-gild (github.com/tfausak/cabal-gild) formats *.cabal plus
      # cabal.project/cabal.project.local, and can discover module lists from
      # the filesystem via `-- cabal-gild: discover <dir>` pragmas.
      programs.cabal-gild.enable = true;
    };
  };
}
