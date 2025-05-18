{
  description = "Flake to build the crux project";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in
  {
    # packages.tracy-client = pkgs.callPackage ./tracy.nix {};

    devShell.${system} = pkgs.mkShell {
      packages = with pkgs; [
        tracy-glfw
        libGL
      ];
      shellHook = ''
        export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [
          # (self.packages.tracy-client)
          pkgs.libGL
        ]}
      '';
    };
  };
}
