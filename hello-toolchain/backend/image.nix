{
  flake,
  stdenv,
  dockerTools,
  ...
}:
let
  flakePackages = flake.packages.${stdenv.hostPlatform.system};
in
dockerTools.buildLayeredImage {
  name = "hello-toolchain-backend";
  tag = "1.0.0";

  fromImage = flakePackages.base-image;

  contents = [ flakePackages.hello-toolchain-backend ];

  config.Entrypoint = [ "hello-toolchain-backend" ];
}
