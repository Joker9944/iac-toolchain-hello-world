{
  lib,
  dockerTools,
  base-image,
  hello-toolchain-backend,
  ...
}:
dockerTools.buildLayeredImage {
  name = "hello-toolchain-backend";
  tag = "1.0.0";

  fromImage = base-image;

  contents = [ hello-toolchain-backend ];

  config.Entrypoint = [ (lib.getExe hello-toolchain-backend) ];
}
