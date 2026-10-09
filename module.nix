# Self-hosted GitHub Actions runners for the glasshome org: ephemeral, one
# system user each, rootless Podman behind the `docker` command.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.glasshome.ciRunner;
  podman = config.virtualisation.podman.package;
  # The runner's sandbox implies NoNewPrivileges, which blocks newuidmap; the
  # user's own podman.socket runs outside it.
  docker = pkgs.writeShellScriptBin "docker" ''
    socket="unix:///run/user/$(id -u)/podman/podman.sock"
    export XDG_RUNTIME_DIR="$HOME/.cache/podman-client"
    mkdir -p "$XDG_RUNTIME_DIR"
    exec ${podman}/bin/podman --remote --url "$socket" "$@"
  '';
  indices = lib.range 1 cfg.count;
  units = toString (map (i: "github-runner-${userOf i}") indices);
  standby = pkgs.writeShellScript "ci-runner-standby" ''
    set -o pipefail
    token=$(cat ${cfg.tokenFile})
    while :; do
      idle=$(${pkgs.curl}/bin/curl -fsS -m 10 \
        -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/glasshome/actions/runners?per_page=100" \
        | ${pkgs.jq}/bin/jq --arg label ${lib.escapeShellArg (toString cfg.standbyFor)} \
          '[.runners[] | select(.status == "online" and (.busy | not) and any(.labels[]; .name == $label))] | length') \
        || exit 0
      [ "$idle" -eq 0 ] && exit 0
      sleep 30
    done
  '';
  upgrade = ''
    set -euo pipefail
    state=/var/lib/ci-runner-upgrade
    mkdir -p "$state"
    token=$(cat ${cfg.tokenFile})
    export NIX_CONFIG="access-tokens = github.com=$token"
    busy() { pgrep -u "$(systemctl show -p User --value "$1")" -f Runner.Worker >/dev/null; }
    healthy() {
      for unit in ${units}; do
        case "$(systemctl show -p ActiveState --value "$unit")/$(systemctl show -p SubState --value "$unit")" in
          active/* | activating/start-pre) ;;
          *) return 1 ;;
        esac
      done
    }

    new=$(nix build --no-link --print-out-paths --refresh --no-write-lock-file \
      --override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable \
      "${toString cfg.upgradeFlake}#nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel")
    if [ "$new" != "$(readlink -f /run/current-system)" ] && [ "$new" != "$(cat "$state/refused" 2>/dev/null)" ]; then
      nix-env -p /nix/var/nix/profiles/system --set "$new"
      # Exits 4 when a unit fails to start; the health check below decides.
      "$new/bin/switch-to-configuration" switch || true
      for unit in ${units}; do busy "$unit" || systemctl restart --no-block "$unit"; done
      ok=0
      for _ in $(seq 1 10); do
        sleep 60
        if healthy; then ok=$((ok + 1)); [ "$ok" -ge 3 ] && break; else ok=0; fi
      done
      if [ "$ok" -lt 3 ]; then
        echo "runners unhealthy on $new, rolling back"
        echo "$new" > "$state/refused"
        nix-env -p /nix/var/nix/profiles/system --rollback
        /nix/var/nix/profiles/system/bin/switch-to-configuration switch || true
        for unit in ${units}; do busy "$unit" || systemctl restart --no-block "$unit"; done
        exit 1
      fi
    fi

    booted=$(readlink -f /run/booted-system/kernel)
    current=$(readlink -f /run/current-system/kernel)
    hour=$(date +%H)
    if [ "$booted" != "$current" ] && [ "$hour" -ge 3 ] && [ "$hour" -lt 5 ]; then
      for unit in ${units}; do busy "$unit" && exit 0; done
      systemctl reboot
    fi
  '';
  userOf = i: "ci-runner-${toString i}";
  homeOf = i: "/var/lib/${userOf i}";
in
{
  options.glasshome.ciRunner = {
    enable = lib.mkEnableOption "glasshome self-hosted GitHub Actions runners";

    count = lib.mkOption {
      type = lib.types.ints.between 1 9;
      default = 1;
      description = "Runners on this host; each takes one job at a time.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Fine-grained PAT, resource owner glasshome, organization permission Self-hosted runners: read and write, no repository access.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.github-runner;
      description = "GitHub stops queueing jobs to a runner 30 days behind the latest release; pass nixpkgs-unstable's when stable lags.";
    };

    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Labels beside glasshome-ci, such as the one a standby host waits on.";
    };

    standbyFor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Label of preferred runners: this host registers only while none of them is online and idle.";
    };

    memoryPerRunner = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "4G";
      description = "MemoryMax per runner, needed once count > 1: gates size their parallelism from it. One CI job needs 3G.";
    };

    upgradeFlake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "github:glasshome/ci-runners";
      description = "Flake this host pulls its configuration from hourly, with nixpkgs updated.";
    };

    blockLocalNetwork = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Drop outgoing traffic to private and link-local addresses except DHCP, and resolve through public DNS, so jobs reach the internet and nothing on the host's network.";
    };

    heartbeatUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File holding a push-monitor URL, called every 5 minutes while every runner service is active.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.nftables.enable = lib.mkIf cfg.blockLocalNetwork true;
    networking.nftables.tables.ci-egress = lib.mkIf cfg.blockLocalNetwork {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority 0; policy accept;
          oifname "lo" accept
          udp dport { 67, 547 } accept
          ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } drop
          ip6 daddr fc00::/7 drop
          ip6 daddr fe80::/10 meta l4proto != ipv6-icmp drop
        }
      '';
    };
    networking.nameservers = lib.mkIf cfg.blockLocalNetwork [
      "1.1.1.1"
      "9.9.9.9"
      "2606:4700:4700::1111"
    ];
    networking.dhcpcd.extraConfig = lib.mkIf cfg.blockLocalNetwork "nohook resolv.conf";

    virtualisation.podman.enable = true;
    systemd.user.sockets.podman.wantedBy = [ "sockets.target" ];
    virtualisation.containers = {
      registries.settings.unqualified-search-registries = [ "docker.io" ];
      containersConf.settings.engine = {
        cgroup_manager = "cgroupfs";
        events_logger = "file";
      };
    };

    # Playwright's Chromium and mise-downloaded binaries are generic Linux builds.
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      glib
      nss
      nspr
      dbus
      expat
      atk
      at-spi2-core
      at-spi2-atk
      cups
      libdrm
      libgbm
      libxkbcommon
      libx11
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxrandr
      libxcb
      libxshmfence
      pango
      cairo
      alsa-lib
      fontconfig
      freetype
    ];

    users.groups.ci-runner = { };
    users.users = lib.listToAttrs (
      map (i: {
        name = userOf i;
        value = {
          isSystemUser = true;
          group = "ci-runner";
          home = homeOf i;
          createHome = true;
          autoSubUidGidRange = true;
          linger = true;
        };
      }) indices
    );

    services.github-runners = lib.listToAttrs (
      map (i: {
        name = userOf i;
        value = {
          enable = true;
          url = "https://github.com/glasshome";
          name = "${config.networking.hostName}-${toString i}";
          inherit (cfg) tokenFile package;
          ephemeral = true;
          replace = true;
          user = userOf i;
          group = "ci-runner";
          extraLabels = [ "glasshome-ci" ] ++ cfg.labels;
          extraPackages = with pkgs; [
            docker
            curl
            gh
            jq
            unzip
            xz
            zstd
            findutils
            gnused
            gawk
            gnugrep
            which
            procps
          ];
          extraEnvironment = {
            # Podman's default OCI format drops HEALTHCHECK.
            BUILDAH_FORMAT = "docker";
            HOME = homeOf i;
          };
          # Registration fails on any network blip; an unattended host retries forever.
          serviceOverrides = import ./sandbox.nix { home = homeOf i; } // {
            Restart = lib.mkForce "always";
            RestartSec = "30s";
          }
          // lib.optionalAttrs (cfg.memoryPerRunner != null) { MemoryMax = cfg.memoryPerRunner; };
        };
      }) indices
    );

    systemd.services = lib.mkMerge [
      (lib.listToAttrs (
        map (i: {
          name = "github-runner-${userOf i}";
          value = {
            startLimitIntervalSec = 0;
            # A switch must not kill a running job; ci-runner-upgrade restarts idle runners itself.
            restartIfChanged = false;
            serviceConfig = lib.mkIf (cfg.standbyFor != null) {
              ExecStartPre = lib.mkBefore [ "+${standby}" ];
              TimeoutStartSec = "infinity";
            };
          };
        }) indices
      ))
      (lib.mkIf (cfg.upgradeFlake != null) {
        ci-runner-upgrade = {
          description = "Pull this host's configuration, switch, and roll back if the runners break";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          restartIfChanged = false;
          unitConfig.X-StopOnRemoval = false;
          serviceConfig.Type = "oneshot";
          path = [
            config.nix.package
            pkgs.coreutils
            pkgs.procps
            pkgs.systemd
          ];
          script = upgrade;
        };
      })
      (lib.listToAttrs (
        map (i: {
          name = "ci-runner-prune-${toString i}";
          value = {
            description = "Prune ${userOf i}'s Podman store and package caches";
            serviceConfig = {
              Type = "oneshot";
              User = userOf i;
              WorkingDirectory = homeOf i;
            };
            environment.HOME = homeOf i;
            script = ''
              ${docker}/bin/docker system prune --all --force --filter until=168h
              ${docker}/bin/docker volume prune --force
              find ${homeOf i}/.bun/install/cache -mindepth 1 -maxdepth 1 -atime +30 -exec rm -rf {} + 2>/dev/null || true
            '';
          };
        }) indices
      ))
      (lib.mkIf (cfg.heartbeatUrlFile != null) {
        ci-runner-heartbeat = {
          description = "Report that every CI runner on this host is up";
          serviceConfig.Type = "oneshot";
          script = ''
            for i in ${toString indices}; do
              ${pkgs.systemd}/bin/systemctl is-active --quiet "github-runner-ci-runner-$i" || exit 0
            done
            ${pkgs.curl}/bin/curl -fsS -m 10 "$(cat ${cfg.heartbeatUrlFile})" >/dev/null
          '';
        };
      })
    ];

    systemd.timers = lib.mkMerge [
      (lib.listToAttrs (
        map (i: {
          name = "ci-runner-prune-${toString i}";
          value = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "weekly";
              Persistent = true;
              RandomizedDelaySec = "1h";
            };
          };
        }) indices
      ))
      (lib.mkIf (cfg.upgradeFlake != null) {
        ci-runner-upgrade = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "10m";
            OnUnitInactiveSec = "1h";
            RandomizedDelaySec = "5m";
          };
        };
      })
      (lib.mkIf (cfg.heartbeatUrlFile != null) {
        ci-runner-heartbeat = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = "5m";
          };
        };
      })
    ];
  };
}
