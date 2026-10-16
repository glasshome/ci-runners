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
      runnerNames =
        host: map (i: "${host}-${toString i}") (nixpkgs.lib.range 1 hosts.${host}.count);
      # ci-b takes jobs first; ci-a registers only while every ci-b runner is busy or offline.
      hosts = {
        # 10 GB VM, 4 vCPU.
        ci-a = {
          count = 2;
          memoryPerRunner = "4500M";
          standbyFor = runnerNames "ci-b";
        };
        # 10.5 GB VM, 16 vCPU, on the travelling mini PC beside the 2 GB HA test VM.
        ci-b = {
          count = 4;
          memoryPerRunner = "3000M";
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
