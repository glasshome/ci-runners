# Boots under BIOS or UEFI, whichever the hypervisor offers.
{ lib, pkgs, ... }:
{
  # The image is small to upload; the root partition grows to whatever disk the VM gets.
  boot.growPartition = true;
  fileSystems."/".autoResize = true;

  disko.imageBuilder = {
    imageFormat = "qcow2";
    # disko passes vmTools an aggregated module tree, which current nixpkgs cannot name the kernel image of.
    pkgs = pkgs.extend (_: prev: { vmTools = prev.vmTools.override { kernelImage = "bzImage"; }; });
  };
  disko.devices.disk.main = {
    type = "disk";
    device = lib.mkDefault "/dev/vda";
    imageSize = "24G";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02";
        };
        esp = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
