# Project-specific flake wiring. seihou never generates, touches, or migrates
# this file, so it is the conflict-free home for anything beyond the managed
# ./nix modules. See flake.module.nix.example for the full option reference.
{ inputs, ... }:
{
  perSystem = { pkgs, ... }:
    let
      haskellPackages = pkgs.haskell.packages.ghc9124;
    in
    {
      # Extra dev-shell tools (merged into the managed ./nix/haskell.nix shell via
      # its haskellProject.extraDevPackages option — no edit to the managed file).
      #
      # git is load-bearing here, not a convenience: automation reactions run as
      # `nix develop --command`, and the daemon's own PATH does not carry
      # ~/.nix-profile/bin. Without git in the shell, scripts/record-release.sh
      # dies on `git for-each-ref` with "tool 'git' not found". An interactive
      # shell hides this by inheriting git from the ambient profile; the dev
      # shell must supply its own.
      haskellProject.extraDevPackages = [ pkgs.git ];

      # A Nix package output for the core `baikai` library is intentionally NOT
      # enabled. `callCabal2nix` resolves dependencies against nixpkgs'
      # `haskell.packages.ghc9124` set, which diverges from the Hackage versions
      # this project's cabal.project resolves — e.g. nixpkgs marks `openai` broken,
      # so `nix build .#default` fails outright. Making it build means overriding
      # every mismatched/broken dependency to match the project's pins, which the
      # dev-shell + cabal workflow already handles correctly.
      #
      # To enable it anyway, build a curated package set (unbreak/override the
      # offending deps) and wire, for example:
      #
      #   packages.default =
      #     let hs = haskellPackages.override {
      #           overrides = self: super: {
      #             openai = pkgs.haskell.lib.markUnbroken super.openai;
      #             # …pin/override other deps to the cabal.project versions…
      #           };
      #         };
      #     in hs.callCabal2nix "baikai" (inputs.self + "/baikai") { };
    };
}
