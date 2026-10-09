{
  description = "glasshome self-hosted CI runner module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, disko, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      # ci-b takes jobs first; ci-a registers only while every ci-b runner is busy or offline.
      hosts = {
        ci-a = {
          count = 1;
          standbyFor = "fast";
        };
        ci-b = {
          count = 1;
          labels = [ "fast" ];
        };
      };
    in
    {
      nixosModules.default = ./module.nix;

      nixosConfigurations = builtins.mapAttrs (
        name: runners:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            ./host.nix
            {
              networking.hostName = name;
              glasshome.ciRunner = runners;
            }
          ];
        }
      ) hosts;

      checks.x86_64-linux.sandbox = pkgs.testers.runNixOSTest (import ./test.nix);
    };
}
