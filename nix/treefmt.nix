# treefmt-nix as a flake-parts module (wires `nix fmt` + a treefmt flake check).
# fourmolu and cabal-fmt are taken from the ghc9124 package set so they match the
# project's compiler. Formatter set preserved from the old top-level treefmt.nix:
# nixpkgs-fmt + fourmolu + cabal-fmt.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = { pkgs, ... }:
    let
      haskellPkgs = pkgs.haskell.packages.ghc9124;
    in
    {
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
        programs.fourmolu.package = haskellPkgs.fourmolu;
        programs.cabal-fmt.enable = true;
        programs.cabal-fmt.package = haskellPkgs.cabal-fmt;
      };
    };
}
