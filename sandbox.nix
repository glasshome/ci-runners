# systemd overrides on top of the github-runner module's hardening. Podman runs
# outside this sandbox (the runner user's podman.socket), so the job only needs
# to reach that socket under /run/user.
{ home }:
{
  ProtectHome = "read-only";
  # The runner user's bun, Playwright and mise caches persist between jobs.
  ReadWritePaths = [ home ];
}
