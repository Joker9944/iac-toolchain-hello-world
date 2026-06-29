{
  flake,
  stdenv,
  dockerTools,
  static-web-server,
  ...
}:
let
  flakePackages = flake.packages.${stdenv.hostPlatform.system};
in
dockerTools.buildLayeredImage {
  name = "hello-toolchain-frontend";
  tag = "1.0.0";

  fromImage = flakePackages.base-image;

  contents = [
    static-web-server
    flakePackages.hello-toolchain-frontend
  ];

  config = {
    Env = [
      "SERVER_PORT=8080"
      "SERVER_ROOT=${flakePackages.hello-toolchain-frontend}"
      "SERVER_HEALTH=true"
    ];

    Entrypoint = [ "static-web-server" ];
  };
}
