{
  description = "Crux minecraft server implementation";
  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        tracyClient = pkgs.callPackage ./nix/tracy-client.nix {};
        tracyProfiler = pkgs.tracy;
        
        odin = pkgs.odin.overrideAttrs (old: {
         version = "dev-2026-11--a1afc819e";
          src = pkgs.fetchFromGitHub {
            owner = "odin-lang";
            repo = "Odin";
            rev = "a1afc819e325810e0c017e62eff4e7ecc59f9087";
            hash = "sha256-wbsc1RmoK9u8TwmMINPdZ+Nqi4Y8aZUmzSlAFmMagzQ=";
          };
        });
      in
      {
        packages.tracyClient = tracyClient;
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "crux";
          version = "0.1";
          src = ./.;
          
          postPatch = ''
            substituteInPlace lib/tracy/bindings.odin \
              --replace-fail '"tracy.so"' '"system:TracyClient"'
          '';
          
          nativeBuildInputs = [ odin ];
          buildInputs = [ tracyClient pkgs.zlib ];
          
          installPhase = ''
            runHook preInstall
            install -Dm755 build/crux $out/bin/crux
            runHook postInstall
          '';
        };
        
        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.default ];
          packages = [ tracyProfiler pkgs.gnumake ];
        };
        
        # nix run
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/crux";
        };
      }
    );
}
