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
      # GitHub cannot filter runners by label, only by name, so a label resolves to names here.
      runnersLabelled =
        label:
        nixpkgs.lib.concatLists (
          nixpkgs.lib.mapAttrsToList (
            host: runners:
            nixpkgs.lib.optionals (builtins.elem label (runners.labels or [ ])) (
              map (i: "${host}-${toString i}") (nixpkgs.lib.range 1 runners.count)
            )
          ) hosts
        );
      # Every job runs on a fast runner and queues when all are busy. ci-a stays defined with no
      # runners: its 4 vCPU run the journeys twice as long as ci-b and they time out (2026-11-02).
      # Raise count to bring it back as a standby.
      hosts = {
        # 10 GB VM, 4 vCPU.
        ci-a = {
          count = 0;
          memoryPerRunner = "3000M";
          standbyFor = runnersLabelled "fast";
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
