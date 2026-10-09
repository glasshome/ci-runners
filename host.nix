# A dedicated runner VM, flashed from image.sh; it then pulls its configuration
# from this repository's main branch.
{ ... }:
{
  imports = [
    ./module.nix
    ./disk.nix
  ];

  networking.useDHCP = true;
  time.timeZone = "UTC";

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
    "ahci"
    "sd_mod"
    "sr_mod"
  ];
  services.qemuGuest.enable = true;
  zramSwap.enable = true;

  # Console only; image.sh writes the hash, and a blank password leaves root locked.
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = "/var/lib/ci-secrets/root-password";

  glasshome.ciRunner = {
    enable = true;
    tokenFile = "/var/lib/ci-secrets/token";
    upgradeFlake = "github:glasshome/ci-runners";
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  system.stateVersion = "26.11";
}
