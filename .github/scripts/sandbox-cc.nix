{ rev, target }:
let
  flake = builtins.getFlake "github:simplex-chat/simplex-chat/${rev}";
  android = haskellNix: example:
    let prev = haskellNix.legacyPackages.x86_64-linux; in
    (import prev.path {
      system = "x86_64-linux";
      inherit (prev) overlays;
      crossSystem = prev.lib.systems.examples.${example} // { sdkVer = "26"; };
    }).stdenv.cc;
  compilers = {
    armv7a = android flake.inputs.haskellNix-ghc8107 "armv7a-android-prebuilt";
    aarch64 = android flake.inputs.haskellNix "aarch64-android";
    ios = flake.inputs.haskellNix.legacyPackages.aarch64-darwin.stdenv.cc;
  };
in
compilers.${target}
