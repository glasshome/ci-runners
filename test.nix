# Runs what the image workflows do, as a runner user under the runner
# service's own systemd hardening, offline.
{ pkgs, ... }:
let
  base = pkgs.dockerTools.buildImage {
    name = "probe-base";
    tag = "latest";
    copyToRoot = [ pkgs.busybox ];
    config.Cmd = [ "/bin/sh" ];
  };
  context = pkgs.runCommand "probe-context" { } ''
    mkdir -p $out/apps/one $out/apps/two
    echo one > $out/apps/one/package.json
    echo two > $out/apps/two/package.json
    echo ok > $out/index.html
    cat > $out/Dockerfile <<'EOF'
    # syntax=docker/dockerfile:1.7-labs
    FROM localhost/probe-base:latest
    COPY --parents apps/*/package.json /srv/
    RUN --mount=type=cache,target=/var/cache/probe touch /var/cache/probe/hit && test -f /srv/apps/two/package.json
    COPY index.html /www/index.html
    HEALTHCHECK --interval=30s CMD wget -q -O - http://127.0.0.1:8080/ || exit 1
    CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
    EOF
  '';
  probe = pkgs.writeShellScript "probe" ''
    set -euxo pipefail
    ${pkgs.chromium}/bin/chromium --headless --no-sandbox --disable-gpu --user-data-dir="$HOME/chromium" \
      --dump-dom 'data:text/html,<p>rendered</p>' | grep -q rendered
    docker load -i ${base}
    cp -r ${context} ctx && chmod -R u+w ctx
    docker build -t probe ctx
    docker image inspect probe | grep -q '"Healthcheck"'
    docker run -d --name published -p 127.0.0.1::8080 probe
    url="http://$(docker port published 8080 | head -n1)"
    for i in $(seq 1 30); do curl -fsS "$url/" && break; sleep 1; done
    curl -fsS "$url/" | grep -q ok
    # The container calls back to a listener on the runner side through the host gateway.
    ${pkgs.python3}/bin/python3 -u -m http.server 0 --bind 0.0.0.0 --directory ctx > callback.log 2>&1 &
    callback=$!
    for i in $(seq 1 30); do port=$(grep -oE 'port [0-9]+' callback.log | grep -oE '[0-9]+' || true); [ -n "$port" ] && break; sleep 1; done
    docker run --rm --add-host host.docker.internal:host-gateway probe wget -q -O - "http://host.docker.internal:$port/index.html" | grep -q ok
    kill "$callback"
    docker rm -f published
    # A container that exits after each job comes back on the same host port.
    port=$(${pkgs.python3}/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    docker run -d --name restarting --restart unless-stopped -p "127.0.0.1:$port:8080" probe sh -c 'httpd -p 8080 -h /www; sleep 3'
    for i in $(seq 1 30); do [ "$(docker inspect restarting --format '{{.RestartCount}}')" -ge 2 ] && break; sleep 1; done
    docker inspect restarting --format '{{.State.Status}} restarts={{.RestartCount}}'
    test "$(docker inspect restarting --format '{{.RestartCount}}')" -ge 2
    for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$port/" && break; sleep 1; done
    curl -fsS "http://127.0.0.1:$port/" | grep -q ok
    docker rm -f restarting
    echo token | docker login 127.0.0.1:5000 -u probe --password-stdin
    docker tag probe 127.0.0.1:5000/probe:ci
    docker push 127.0.0.1:5000/probe:ci
    curl -fsS http://127.0.0.1:5000/v2/probe/manifests/ci -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' | grep -q '"mediaType"'
    if curl -fsS -m 5 http://192.168.1.1:8000/; then echo "reached the local network"; exit 1; fi
    if docker run --rm probe wget -q -T 5 -O - http://192.168.1.1:8000/; then echo "a container reached the local network"; exit 1; fi
    docker run -d --name logs probe sh -c 'echo from-the-container; sleep 30'
    sleep 3
    docker logs logs | grep -q from-the-container || { echo "docker logs returned nothing"; docker logs logs; exit 1; }
    docker rm -f logs
    touch "$HOME/probe-passed"
  '';
in
{
  name = "ci-runner-sandbox";

  nodes.lan =
    { pkgs, ... }:
    {
      networking.firewall.allowedTCPPorts = [ 8000 ];
      systemd.services.http = {
        wantedBy = [ "multi-user.target" ];
        script = "echo ok > /tmp/index.html && exec ''${pkgs.python3}/bin/python3 -m http.server 8000 --directory /tmp";
      };
    };

  nodes.machine =
    { config, lib, ... }:
    let
      runner = config.systemd.services.github-runner-ci-runner-1;
    in
    {
      imports = [ ./module.nix ];
      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 8192;

      glasshome.ciRunner = {
        enable = true;
        tokenFile = "/dev/null";
      };
      services.dockerRegistry = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 5000;
      };
      virtualisation.containers.registries.settings.registry = [
        {
          location = "127.0.0.1:5000";
          insecure = true;
        }
      ];
      # No GitHub in the sandbox: keep the runner's unit, never start it.
      systemd.services.github-runner-ci-runner-1.wantedBy = lib.mkForce [ ];

      systemd.services.probe = {
        environment = runner.environment // {
          PATH = lib.mkForce runner.environment.PATH;
        };
        serviceConfig =
          builtins.removeAttrs runner.serviceConfig [
            "ExecStart"
            "ExecStartPre"
            "ExecStopPost"
            "Restart"
            "RestartForceExitStatus"
            "InaccessiblePaths"
            "WorkingDirectory"
            "BindPaths"
          ]
          // {
            Type = "oneshot";
            WorkingDirectory = "/var/lib/ci-runner-1";
            ExecStart = probe;
          };
      };
    };

  testScript =
    { nodes, ... }:
    let
      runner = nodes.machine.services.github-runners.ci-runner-1.package;
    in
    ''
    start_all()
    # hashFiles() runs <runner root>/externals/node20 on runner 2.337.
    machine.succeed("${runner}/lib/externals/node20/bin/node -e 1 && test -e ${runner}/lib/github-runner/hashFiles")
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("docker-registry.service")
    machine.wait_until_succeeds("test -S /run/user/$(id -u ci-runner-1)/podman/podman.sock")
    machine.succeed("systemctl start probe.service || (journalctl -u probe --no-pager | tail -60; journalctl _UID=$(id -u ci-runner-1) --no-pager | grep -iE 'restart|cleanup|conmon|error' | tail -30; exit 1)")
    machine.succeed("test -f /var/lib/ci-runner-1/probe-passed")
    machine.succeed("test \"$(stat -c %U /var/lib/ci-runner-1/work)\" = ci-runner-1")
    lan.wait_for_open_port(8000)
    lan.succeed("ip -4 addr | grep -q 192.168.1.1/")
    machine.fail("curl -fsS -m 5 http://192.168.1.1:8000/")
    machine.succeed("nft delete table inet ci-egress && curl -fsS -m 5 http://192.168.1.1:8000/ | grep -q ok")
  '';
}
