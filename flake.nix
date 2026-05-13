{
  description = "baikai is a Haskell library that provides a unified abstraction over AI providers such as OpenAI, Anthropic, and others.";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        haskellPackages = pkgs.haskell.packages."ghc912";
      in
      {
        packages = {
          default = haskellPackages.baikai;
        };

        checks = {
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.zlib
            pkgs.just
            pkgs.cabal-install
            pkgs.pkg-config
            (haskellPackages.ghcWithPackages (ps: [
              ps.haskell-language-server
            ]))
          ]
          ++ pkgs.lib.optional false pkgs.process-compose;

          shellHook = ''
            export LANG=en_US.UTF-8
          '';
        };
      }
    );
}
