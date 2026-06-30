{
  description = "guide dev env flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils/main";
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
    in
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
            pulumiPackages.pulumi-go
            kubectl
            skopeo
            kpt
          ];
        };

        packages =
          let
            flakePackages = self.packages.${system};
          in {
          # programs
          hello-toolchain-backend = pkgs.callPackage ./hello-toolchain/backend/package.nix { };
          hello-toolchain-frontend = pkgs.callPackage ./hello-toolchain/frontend/package.nix { };

          # images
          base-image = pkgs.callPackage ./hello-toolchain/base-image.nix { };
          hello-toolchain-backend-image = pkgs.callPackage ./hello-toolchain/backend/image.nix {
            inherit (flakePackages) base-image hello-toolchain-backend;
          };
          hello-toolchain-frontend-image = pkgs.callPackage ./hello-toolchain/frontend/image.nix {
            inherit (flakePackages) base-image hello-toolchain-frontend;
          };

          # scripts
          push-images = pkgs.writeShellApplication {
            name = "push-images";
            runtimeInputs = with pkgs; [
              azure-cli
              skopeo
              pulumi
            ];
            text = ''
              TAG=''${1:-latest}
              API_BASE_URL=''${2:-}

              ACR_SERVER=$(pulumi -C hello-toolchain/infra stack output registryLoginServer)
              TOKEN=$(az acr login --name "''${ACR_SERVER%%.*}" --expose-token --output tsv --query accessToken)

              BACKEND_IMAGE=$(nix build --no-link --print-out-paths ${./.}#hello-toolchain-backend-image)

              FRONTEND_IMAGE=$(
                API_BASE_URL="$API_BASE_URL" \
                nix build --impure --no-link --print-out-paths --expr "
                  let
                    pkgs = (builtins.getFlake \"${./.}\").packages.${system};
                    frontend = pkgs.hello-toolchain-frontend.override { apiBaseUrl = builtins.getEnv \"API_BASE_URL\"; };
                  in
                    pkgs.hello-toolchain-frontend-image.override { hello-toolchain-frontend = frontend; }
                "
              )

              skopeo copy --insecure-policy \
                docker-archive:"$BACKEND_IMAGE" \
                docker://"$ACR_SERVER"/hello-backend:"$TAG" \
                --dest-creds "00000000-0000-0000-0000-000000000000:$TOKEN"

              skopeo copy --insecure-policy \
                docker-archive:"$FRONTEND_IMAGE" \
                docker://"$ACR_SERVER"/hello-frontend:"$TAG" \
                --dest-creds "00000000-0000-0000-0000-000000000000:$TOKEN"
            '';
          };
        };

        apps.push-images = {
          type = "app";
          program = lib.getExe self.packages.${system}.push-images;
        };
      }
    );
}
