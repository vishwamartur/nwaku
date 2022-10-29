{
  description = "Nix flake for nim-waku.";

  inputs.nixpkgs.url = github:NixOS/nixpkgs/nixos-22.05;

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "i686-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });

      buildPackage = system: subPackages:
        let pkgs = nixpkgsFor.${system};
        in pkgs.callPackage ./build.nix { };
    in rec {
      packages = forAllSystems (system: {
        node    = buildPackage system ["cmd/waku"];
        library = buildPackage system ["library"];
        dbutils = buildPackage system ["dbutils"];
      });

      defaultPackage = forAllSystems (system:
        buildPackage system ["cmd/waku"]
      );

      #devShell = packages.${system}.node;
  };
}
