{ buildGoModule, ... }:
buildGoModule (finalAttrs: {
  pname = "hello-toolchain-backend";
  version = "1.0.0";

  src = ./.;

  vendorHash = null;

  meta.mainProgram = finalAttrs.pname;
})
