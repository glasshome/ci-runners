# ci-runners

NixOS configuration for the self-hosted GitHub Actions runners of the glasshome organization: ephemeral runners, one system user each, rootless Podman behind the `docker` command.

## What a job gets

- `docker` is `podman --remote` on the runner user's own Podman socket. Use the plain CLI (`build`, `run`, `port`, `logs`, `login`, `push`, `rm`); BuildKit actions such as `docker/build-push-action` do not work.
- `BUILDAH_FORMAT=docker` is set, so images keep their `HEALTHCHECK`.
- Runners on one host share a Podman store: name containers per run, remove them in an `if: always()` step, and publish to random ports (`-p 127.0.0.1::PORT`, then `docker port`).
- Nothing but the job's own `GITHUB_TOKEN`; keep jobs that need other secrets on GitHub-hosted runners.
- Tools beyond the base system come from `extraPackages` in `module.nix`.

## Hosts

`flake.nix` lists them. Each runner registers as `<host>-<n>` with the label `glasshome-ci`.

- `ci-b`: runners labelled `fast`, which take jobs first.
- `ci-a`: one standby runner. It registers only while no `fast` runner is online and idle, so jobs prefer the faster host and still run while it is away.

One CI job needs 3 GB of memory. With `count` above 1, set `memoryPerRunner` so each runner's jobs size their parallelism to their share.

## Flashing a host

1. `./image.sh <host> ~/<host>.img`. It asks for the runner PAT and an optional console root password, and writes a fully allocated raw disk (24 GB) with both inside.
2. Import it as the system disk of a new VM: 2 or more vCPUs, 5 GB RAM per runner, no shared folders. Grow the disk to 60 GB if the hypervisor allows; the root partition follows on boot.
3. Boot it and delete the `.img`. The runners appear under the organization's Settings, Actions, Runners.

A host that travels must not start its VM on boot: a runner online on a foreign network joins the pool and takes jobs.

**PAT:** fine-grained, resource owner `glasshome`, organization permission "Self-hosted runners: read and write", no repository access. It expires; reflash with a new one before the date on it.

**Organization setting:** Settings, Actions, Runner groups, Default must not allow public repositories. This repository is public and runs its own CI on GitHub-hosted runners.

## Network

The VM runs IPv4 only, drops outgoing traffic to private and link-local addresses (DHCP excepted) and resolves through public DNS, so jobs and their containers reach the internet and nothing on the host's network. Jobs run unprivileged and cannot change the rules. A host that can also sit on an isolated network segment should.

## Updates

Every 15 minutes each host builds its configuration from this repository's `main` at the nixpkgs `flake.lock` pins. A daily workflow updates the lock, runs the VM test, and commits only when it passes, which also keeps the runner inside GitHub's 30-day support window. A changed system is switched to. Runners GitHub reports idle restart onto it at once, the rest after their job. If a runner stays unhealthy for 10 minutes after the switch, the host rolls back and refuses that exact system until the configuration or nixpkgs moves. A changed kernel reboots the host between 03:00 and 05:00 UTC when no job runs.

So a push to `main` reaches every runner within 15 minutes, as root. CI runs the VM test on every push and pull request; merge only on green.

`ci-status` on the console prints the runners, their recent log, the last upgrade, disk and memory.

Recovery when a host is down: pick the previous generation in the boot menu from the hypervisor console, or flash a fresh image.

## Testing

`nix build .#checks.x86_64-linux.sandbox -L` runs the image workflow steps in a VM as a runner user under the runner's own hardening, offline: a build with `COPY --parents`, a cache mount and `HEALTHCHECK`, a published-port run, a container calling back to the runner through the host gateway, a restart policy, and login and push to a local registry.
