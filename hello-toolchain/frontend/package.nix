{ flutter, ... }:
flutter.buildFlutterApplication (finalAttrs: {
  pname = "hello-toolchain-frontend";
  version = "1.0.0";

  targetFlutterPlatform = "web";

  src = ./.;

  autoPubspecLock = ./pubspec.lock;
})
