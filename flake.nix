{
  description = "guide dev env flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils/main";
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          name = "hello-toolchain-dev";

          packages = with pkgs; [
            azure-cli
            go
            flutter
            dart
            pulumi
            pulumictl
            pulumiPackages.pulumi-go
          ];
        };

        packages = {
          # programs
          hello-toolchain-backend = pkgs.callPackage ./hello-toolchain/backend/package.nix { flake = self; };
          hello-toolchain-frontend = pkgs.callPackage ./hello-toolchain/frontend/package.nix {
            flake = self;
          };

          # images
          base-image = pkgs.callPackage ./hello-toolchain/base-image.nix { flake = self; };
          hello-toolchain-backend-image = pkgs.callPackage ./hello-toolchain/backend/image.nix {
            flake = self;
          };
          hello-toolchain-frontend-image = pkgs.callPackage ./hello-toolchain/frontend/image.nix {
            flake = self;
          };
        };
      }
    );
}
