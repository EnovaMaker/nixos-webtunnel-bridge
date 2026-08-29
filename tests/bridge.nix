{ pkgs, module }:

let
  domain = "bridge.test";
  orPort = 19001;

  # No public domain exists inside a test VM, so ACME cannot run here. This is
  # the reason the module carries acme.enable at all: without an escape hatch
  # the module would be untestable, which is a poor property for a module whose
  # whole claim is that it is tested.
  #
  # Two certificates with different lifetimes. The expiry check has to tell
  # them apart, and swapping one for the other without reloading nginx is
  # what proves the check reads the served certificate rather than the file
  # on disk -- ACME renewing while the server keeps serving the old one is
  # the failure that actually bites operators.
  mkCert = name: days: pkgs.runCommand name { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes -days ${toString days} \
      -subj "/CN=${domain}" \
      -addext "subjectAltName=DNS:${domain}" \
      -keyout $out/key.pem -out $out/cert.pem
  '';

  freshCert = mkCert "cert-fresh" 400;
  staleCert = mkCert "cert-stale" 1;

  # nginx reads these at runtime, so the test can replace them mid-run. A
  # store path is immutable and the swap could not be staged.
  certDir = "/var/lib/webtunnel-test-certs";
in
pkgs.testers.runNixOSTest {
  name = "webtunnel-bridge";

  nodes.bridge = { ... }: {
    imports = [ module ];

    services.tor-webtunnel-bridge = {
      enable = true;
      inherit domain;
      path = "/vRsQ4Nk2";
      contactInfo = "ops@bridge.test";
      inherit orPort;
      acme.enable = false;
      tls.certFile = "${certDir}/cert.pem";
      tls.keyFile = "${certDir}/key.pem";
    };

    # Seed the mutable certificate directory before nginx starts. In a real
    # deployment ACME owns these files and sets their permissions; here the
    # test has to stand in for it, which is why ownership is set explicitly.
    system.activationScripts.seedTestCert = {
      deps = [ "users" ];
      text = ''
        mkdir -p ${certDir}
        cp ${freshCert}/cert.pem ${certDir}/cert.pem
        cp ${freshCert}/key.pem ${certDir}/key.pem
        chown nginx:nginx ${certDir}/cert.pem ${certDir}/key.pem
        chmod 644 ${certDir}/cert.pem
        chmod 600 ${certDir}/key.pem
      '';
    };

    environment.etc."stale-cert.pem".source = "${staleCert}/cert.pem";
    environment.etc."stale-key.pem".source = "${staleCert}/key.pem";

    # Tor writes its identity keys here. Losing them changes the bridge's
    # fingerprint, which is what the migration in M2 has to avoid.
    virtualisation.memorySize = 1024;
  };

  testScript = ''
    bridge.start()

    with subtest("nginx serves the cover site on every other path"):
        bridge.wait_for_unit("nginx.service")
        bridge.wait_for_open_port(443)
        bridge.succeed(
            "curl -sSf --resolve ${domain}:443:127.0.0.1 --cacert ${freshCert}/cert.pem "
            "https://${domain}/ | grep -q '<html'"
        )

    with subtest("tor starts and registers the webtunnel transport"):
        bridge.wait_for_unit("tor.service")
        bridge.wait_until_succeeds(
            "journalctl -u tor.service | grep -q 'Registered server transport .webtunnel.'",
            timeout=120,
        )

    with subtest("the transport is listening where nginx expects it"):
        bridge.wait_for_open_port(15000)

    with subtest("tor holds an identity, and it is the thing migration must preserve"):
        bridge.succeed("test -s /var/lib/tor/keys/ed25519_master_id_secret_key")

    with subtest("the transport path is not logged"):
        bridge.succeed(
            "curl -sk --resolve ${domain}:443:127.0.0.1 "
            "https://${domain}/vRsQ4Nk2 -o /dev/null || true"
        )
        bridge.fail("grep -q vRsQ4Nk2 /var/log/nginx/access.log")

    with subtest("the generated torrc matches upstream's required settings"):
        # NixOS generates the torrc into the store and passes it with -f,
        # so find it from the unit rather than guessing a path.
        torrc = bridge.succeed(
            "cat $(systemctl show tor.service -p ExecStart --value "
            "| tr ' ' '\n' | grep -A1 -- '-f' | tail -1)"
        )
        for needed in [
            "BridgeRelay 1",
            "AssumeReachable 1",
            "ExtORPort auto",
            "ServerTransportPlugin webtunnel",
            "ServerTransportListenAddr webtunnel 127.0.0.1:15000",
            "ServerTransportOptions webtunnel url=https://bridge.test/vRsQ4Nk2",
        ]:
            assert needed in torrc, "torrc is missing: " + needed

    with subtest("the ORPort listens on loopback and nowhere else"):
        # Asserting only that 0.0.0.0 is absent would also pass if Tor failed
        # to bind at all, so assert the positive first.
        # The port comes from the module's own option rather than a literal,
        # so changing the default cannot silently turn this into a test of
        # nothing.
        bridge.wait_until_succeeds(
            "${pkgs.iproute2}/bin/ss -ltn | grep -q '127.0.0.1:${toString orPort}'",
            timeout=60,
        )
        bridge.fail("${pkgs.iproute2}/bin/ss -ltn | grep -q '0.0.0.0:${toString orPort}'")

    with subtest("torrc pins the ORPort to loopback explicitly"):
        assert "ORPort 127.0.0.1:${toString orPort}" in torrc, "ORPort is not bound to loopback"

    with subtest("the expiry check passes on a certificate with time left"):
        bridge.succeed("systemctl start webtunnel-cert-expiry.service")
        journal = bridge.succeed("journalctl -u webtunnel-cert-expiry --no-pager")
        assert "valid for another" in journal, journal

    with subtest("it reads what is served, not what is on disk"):
        # Replace the certificate files without reloading nginx. A check that
        # read the files would now report an expiring certificate; one that
        # asks the running server still sees the fresh one it is serving.
        bridge.succeed("install -o nginx -g nginx -m 644 /etc/stale-cert.pem ${certDir}/cert.pem")
        bridge.succeed("install -o nginx -g nginx -m 600 /etc/stale-key.pem ${certDir}/key.pem")
        bridge.succeed("systemctl start webtunnel-cert-expiry.service")

    with subtest("and it warns once the server actually serves the old one"):
        bridge.succeed("systemctl reload nginx.service")
        bridge.fail("systemctl start webtunnel-cert-expiry.service")
        journal = bridge.succeed("journalctl -u webtunnel-cert-expiry --no-pager")
        assert "expires in" in journal or "EXPIRED" in journal, journal

    with subtest("the timer is armed"):
        bridge.succeed("systemctl is-active webtunnel-cert-expiry.timer")
  '';
}
