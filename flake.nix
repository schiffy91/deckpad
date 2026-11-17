{
  description = "Deck Pad: the Steam Deck as a Steam Controller";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    btrc = { url = "github:schiffy91/btrc"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, btrc }@inputs:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = body: nixpkgs.lib.genAttrs systems body;
      pkgsFor = system: import nixpkgs { inherit system; };
    in {
      # `artwork` is the shortcut's pictures (icon.png, p.png, landscape.png, _hero.png, _logo.png) as a directory.
      packages = each (system:
        let programs = import ./nix/package.nix { pkgs = pkgsFor system; inherit inputs; };
        in { inherit (programs) deckpad screen tray; artwork = programs.artwork.directory; default = programs.deckpad; });

      nixosModules.default = import ./nix/module.nix { inherit inputs; };

      # `unit-deckpad` runs the unit suite, a host against the real program over loopback, the tray and the
      # screen on a virtual display. `vm-links` runs every link against a real kernel in NixOS guests (KVM).
      checks = each (system: {
        unit-deckpad = import ./tests { pkgs = pkgsFor system; inherit inputs; };
        vm-links = import ./tests/kernel.nix { pkgs = pkgsFor system; inherit inputs; };
      });

      devShells = each (system: {
        default = (pkgsFor system).mkShell { packages = [ btrc.packages.${system}.btrcpy (pkgsFor system).pkg-config ]; };
      });
    };
}
