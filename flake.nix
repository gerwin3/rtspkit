{
  description = "rtspkit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils/11707dc2f618dd54ca8739b309ec4fc024de578b";
    flake-compat = {
      url = "github:edolstra/flake-compat/5edf11c44bc78a0d334f6334cdaf7d60d732daab";
      flake = false;
    };
    zig = {
      url = "github:mitchellh/zig-overlay/7a81937e0992295dec2bfa070da52a79188007a9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zls = {
      url = "github:zigtools/zls/8da87d4f3305a550e7b739bad764e34bf1e46a08";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, ... }@inputs:
    inputs.flake-utils.lib.eachSystem (builtins.attrNames inputs.zig.packages) (
      system:
      let
        overlays = [
          (final: prev: { zigpkgs = inputs.zig.packages.${prev.stdenv.hostPlatform.system}; })
          (final: prev: { zlspkgs = inputs.zls.packages.${prev.stdenv.hostPlatform.system}; })
        ];
        pkgs = import nixpkgs { inherit overlays system; };
      in
      {
        devShells.default = pkgs.mkShell.override { stdenv = pkgs.clangStdenv; } {
          packages = with pkgs; [
            zigpkgs.default
            zls
          ];
        };
      }
    );
}
