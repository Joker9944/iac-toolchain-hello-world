{
  lib,
  flutter,
  apiBaseUrl ? null,
  ...
}:
flutter.buildFlutterApplication (finalAttrs: {
  pname = "hello-toolchain-frontend";
  version = "1.0.0";

  targetFlutterPlatform = "web";

  src = ./.;

  autoPubspecLock = ./pubspec.lock;

  flutterBuildFlags = lib.optional (apiBaseUrl != null) "--dart-define=API_BASE_URL=${apiBaseUrl}";
})
