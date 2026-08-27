{ config, lib, pkgs, ... }:

let
  cfg = config.services.tor-webtunnel-bridge;
in
{
  options.services.tor-webtunnel-bridge = {
    enable = lib.mkEnableOption ''
      a Tor WebTunnel bridge relay behind nginx.

      Upstream's requirements apply and are worth reading before deploying:
      a static IPv4 address, the ability to expose TCP ports, a domain under
      your control with a valid TLS certificate, and **at least 1 GB of RAM,
      with 4 GB recommended**. A 512 MB host will start this and then have
      Tor killed under load, which looks like an intermittent bridge rather
      than an undersized one
    '';

    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.org";
      description = ''
        Domain the bridge answers on. This becomes public: it is part of the
        bridge line handed to users, so it is not a secret. What the design
        protects is the shape of the traffic, not the address.
      '';
    };

    path = lib.mkOption {
      type = lib.types.str;
      example = "/vRsQ4Nk2";
      description = ''
        Path the transport is reached on. Every other path is served by the
        cover site.

        There is no default on purpose. A shared default would make every
        deployment of this module recognisable by a single request.
      '';
    };

    nickname = lib.mkOption {
      type = lib.types.str;
      default = "webtunnelbridge";
      description = "Relay nickname published in Tor's bridge data.";
    };

    contactInfo = lib.mkOption {
      type = lib.types.str;
      example = "ops@example.org";
      description = ''
        Contact address published with the relay, so the Tor Project can reach
        the operator about the bridge.
      '';
    };

    orPort = lib.mkOption {
      type = lib.types.port;
      default = 19001;
      description = ''
        Tor's ORPort, bound to loopback.

        Deliberately not 9001. On a WebTunnel bridge this port never faces the
        network, so upstream's "avoid 9001" instruction -- which exists because
        scanning the canonical Tor port finds bridges -- does not strictly
        apply here. It is avoided anyway, for two reasons: if this port is ever
        exposed by a misconfiguration or a later change, 9001 announces what it
        is, and an obfs4 bridge on the same operator's other host must avoid it
        for real, so keeping one rule is simpler than keeping two.

        It is deliberately not reachable from outside. Users arrive over 443
        and the transport hands them to Tor locally, so nothing needs to reach
        this port from the network — and leaving it exposed would undo the
        cover site's work, since scanning for open ORPorts is a known way to
        find bridges. A host that answers as an ordinary website on 443 and as
        a Tor relay on 9001 is not an ordinary website.

        The VM test asserts this stays closed.
      '';
    };

    transportPort = lib.mkOption {
      type = lib.types.port;
      default = 15000;
      description = "Loopback port nginx proxies the transport path to.";
    };

    coverSite = lib.mkOption {
      type = lib.types.path;
      default = ../cover-site;
      defaultText = lib.literalExpression "../cover-site";
      description = ''
        Document root served on every path except {option}`path`.

        This is part of the security model rather than decoration. A domain
        holding a valid certificate that answers only on one unusual path is
        itself a pattern worth noticing, so the cover site has to be a site.
        The bundled default is a starting point, not something to ship as-is:
        replace it with something that belongs to the domain name.
      '';
    };

    acme = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Obtain the certificate through ACME.

          Set to false to supply {option}`tls.certFile` and
          {option}`tls.keyFile` directly. That is what the VM test does: there
          is no public domain inside a test VM, so ACME cannot run there.
        '';
      };

      email = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Address for ACME expiry notices.";
      };
    };

    tls = {
      certFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Certificate to use when {option}`acme.enable` is false.";
      };

      keyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Private key to use when {option}`acme.enable` is false.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.path;
        message = "services.tor-webtunnel-bridge.path must start with a slash.";
      }
      {
        assertion = cfg.path != "/";
        message = ''
          services.tor-webtunnel-bridge.path must not be "/", which would
          leave no path for the cover site and defeat the point of having one.
        '';
      }
      {
        assertion = cfg.acme.enable || (cfg.tls.certFile != null && cfg.tls.keyFile != null);
        message = ''
          services.tor-webtunnel-bridge: with acme.enable = false you must set
          both tls.certFile and tls.keyFile.
        '';
      }
      {
        assertion = !cfg.acme.enable || cfg.acme.email != "";
        message = "services.tor-webtunnel-bridge.acme.email is required when ACME is enabled.";
      }
    ];

    services.tor = {
      enable = true;
      relay = {
        enable = true;
        role = "bridge";
      };
      settings = {
        Nickname = cfg.nickname;
        ContactInfo = cfg.contactInfo;
        BridgeRelay = true;
        # Loopback, not a bare port. A bare port makes Tor bind 0.0.0.0, which
        # the VM test caught and which would advertise the relay to anyone
        # scanning the host the cover site exists to make unremarkable.
        ORPort = [{ addr = "127.0.0.1"; port = cfg.orPort; }];
        ExtORPort.port = "auto";

        # Required, not optional. With the ORPort on loopback, Tor's own
        # reachability self-test cannot succeed: it tries to reach that port
        # from outside and never will. Without this the bridge decides it is
        # unreachable and never publishes its descriptor, so it exists and
        # serves nobody. Upstream's own torrc sets it for exactly this reason.
        AssumeReachable = true;

        # A bridge has no use for a local SOCKS proxy, and an unused open port
        # is surface for nothing.
        SocksPort = [ "0" ];
        ServerTransportPlugin = {
          transports = [ "webtunnel" ];
          exec = "${pkgs.webtunnel}/bin/server";
        };
        ServerTransportListenAddr = [ "webtunnel 127.0.0.1:${toString cfg.transportPort}" ];
        ServerTransportOptions = [ "webtunnel url=https://${cfg.domain}${cfg.path}" ];
      };
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts.${cfg.domain} = {
        forceSSL = true;
        enableACME = cfg.acme.enable;
        sslCertificate = lib.mkIf (!cfg.acme.enable) cfg.tls.certFile;
        sslCertificateKey = lib.mkIf (!cfg.acme.enable) cfg.tls.keyFile;

        root = cfg.coverSite;

        # Exact match, not a prefix. A prefix would also hand /<path>anything
        # to the transport, which is both wrong and a way to probe for the
        # bridge by guessing suffixes.
        locations."= ${cfg.path}" = {
          proxyPass = "http://127.0.0.1:${toString cfg.transportPort}";
          # The transport speaks HTTP Upgrade. This emits the three lines
          # upstream's own guide specifies -- proxy_http_version 1.1, and
          # Upgrade/Connection headers -- passing through whatever upgrade
          # token the client sends rather than assuming websocket.
          proxyWebsockets = true;
          extraConfig = ''
            # Do not log the people using the bridge. Without this nginx
            # records the source address of every censored user who connects,
            # and writes it to a disk that can be seized. Upstream's guide
            # turns both logs off here for the same reason.
            access_log off;
            error_log /dev/null;

            # Upstream sets this so content negotiation cannot interfere with
            # the upgraded connection.
            proxy_set_header Accept-Encoding "";
          '';
        };
      };
    };

    security.acme = lib.mkIf cfg.acme.enable {
      acceptTerms = true;
      defaults.email = cfg.acme.email;
    };

    # 443 only. The ORPort stays on loopback: reaching Tor from outside is the
    # transport's job, and an open ORPort would advertise what the cover site
    # exists to keep unremarkable.
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
