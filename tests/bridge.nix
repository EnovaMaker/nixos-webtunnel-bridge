{ pkgs, module }:

let
  domain = "bridge.test";

  # No public domain exists inside a test VM, so ACME cannot run here. This is
  # the reason the module carries acme.enable at all: without an escape hatch
  # the module would be untestable, which is a poor property for a module whose
  # whole claim is that it is tested.
  selfSigned = pkgs.runCommand "self-signed-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
      -subj "/CN=${domain}" \
      -addext "subjectAltName=DNS:${domain}" \
      -keyout $out/key.pem -out $out/cert.pem
  '';
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
      acme.enable = false;
      tls.certFile = "${selfSigned}/cert.pem";
      tls.keyFile = "${selfSigned}/key.pem";
    };

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
            "curl -sSf --resolve ${domain}:443:127.0.0.1 --cacert ${selfSigned}/cert.pem "
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

    with subtest("the ORPort is not reachable from outside"):
        bridge.fail("${pkgs.iproute2}/bin/ss -ltn | grep -q '0.0.0.0:9001'")
  '';
}
