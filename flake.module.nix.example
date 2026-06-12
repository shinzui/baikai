# flake.module.nix — your project-specific flake-parts customizations.
#
# Copy this file to `flake.module.nix` (next to flake.nix), then edit it:
#
#     cp flake.module.nix.example flake.module.nix
#
# flake.nix imports it automatically when present:
#
#     imports = [ ... ]
#       ++ nixpkgs.lib.optional (builtins.pathExists ./flake.module.nix) ./flake.module.nix;
#
# seihou does NOT manage flake.module.nix: it is never regenerated or overwritten
# by `seihou run` or by module migrations, so your changes here survive template
# upgrades without conflict. (flake.nix and nix/*.nix ARE seihou-managed — editing
# those means accepting a conflict the next time this module migrates.)
#
# This is an ordinary flake-parts module. See https://flake.parts for the full
# module/option reference.
{ inputs, ... }:
{
  perSystem = { pkgs, config, ... }: {
    # Add project-specific dev-shell tools (conflict-free; reads the option
    # declared in ./nix/haskell.nix):
    #
    #   haskellProject.extraDevPackages = [ pkgs.ghciwatch pkgs.haskellPackages.hpack ];

    # Add extra package / app / check outputs:
    #
    #   packages.my-tool = pkgs.hello;
    #   apps.seed = { type = "app"; program = "${pkgs.writeShellScript "seed" "..."}"; };

    # Extra dev shells compose freely (use a new name to avoid clashing with the
    # generated devShells.default):
    #
    #   devShells.ci = pkgs.mkShellNoCC { packages = [ pkgs.cabal-install ]; };
  };

  # To pull in a brand-new flake input you must add it to flake.nix's top-level
  # `inputs` (a Nix requirement — inputs cannot be declared from an imported
  # module). That is the one edit that will conflict on a future migration;
  # resolve it with "accept new" and re-add your input line.
}
