{
  lib,
  dockerTools,
  static-web-server,
  base-image,
  hello-toolchain-frontend,
  ...
}:
dockerTools.buildLayeredImage {
  name = "hello-toolchain-frontend";
  tag = "1.0.0";

  fromImage = base-image;

  contents = [
    static-web-server
    hello-toolchain-frontend
  ];

  config = {
    Env = [
      "SERVER_PORT=8080"
      "SERVER_ROOT=${hello-toolchain-frontend}"
      "SERVER_HEALTH=true"
    ];

    Entrypoint = [ (lib.getExe static-web-server) ];
  };
}
