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
        # 10 GB VM, 4 vCPU.
        ci-a = {
          count = 2;
          memoryPerRunner = "4500M";
          standbyFor = "fast";
        };
        # 4 GB VM, 8 vCPU, on the travelling mini PC; three runners at 3500M once it has 16 GB.
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
