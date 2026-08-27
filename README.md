# nixos-webtunnel-bridge

A Tor **WebTunnel** bridge relay, declared once.

```nix
services.tor-webtunnel-bridge = {
  enable      = true;
  domain      = "example.org";
  path        = "/vRsQ4Nk2";
  contactInfo = "ops@example.org";
  acme.email  = "ops@example.org";
};
```

That deploys Tor as a bridge relay with the webtunnel pluggable transport, nginx terminating
TLS in front of it, a certificate issued automatically, the transport reachable on one path,
and a cover site on every other path.

---

## Why this exists

A WebTunnel bridge is not another transport switched on an existing relay. It needs its own
domain, a valid TLS certificate and a real web server in front of it, because the point is that
its traffic is indistinguishable from ordinary HTTPS to that site.

Every piece is already in nixpkgs — the `webtunnel` package, Tor's `ServerTransportPlugin`,
nginx, ACME. What was missing was the composition, and getting it wrong is quiet: the bridge
comes up, the certificate is valid, and clients still cannot use it.

## The cover site is not decoration

A domain holding a valid certificate that answers on exactly one unusual path is itself a
pattern worth noticing. The module serves a site on every path except the transport's.

The bundled default is a starting point, **not** something to ship as-is. Replace it with
something that belongs to your domain name.

```nix
services.tor-webtunnel-bridge.coverSite = ./my-site;
```

## Choosing a path

There is no default, on purpose. A shared default would make every deployment of this module
identifiable with a single request.

Pick something unremarkable and unguessable:

```console
$ head -c 9 /dev/urandom | base64 | tr -d '/+=' | sed 's|^|/|'
```

---

## Status

**Early. It works, it is tested, and it is not yet something to trust with anyone's safety.**

What is here:

- the module, deploying a complete bridge from one declaration
- a NixOS VM test covering the plumbing: nginx serves the cover site over TLS, Tor starts and
  registers the transport, the transport listens where nginx proxies to it, Tor holds an
  identity key, and the ORPort is not exposed
- CI running that test

What is not here yet, and matters before you rely on it:

- **an end-to-end test.** The VM test proves the parts are wired together. It does not prove a
  client completes a Tor circuit through the bridge, which needs a private Tor network in the
  test and is the honest boundary of what is verified today
- an edge-case matrix — certificate renewal, restarts, transport crash and recovery
- an external security review
- operator documentation beyond this file
- any meaningful record of behaviour over time

If you run this, run it as an experiment.

## Requirements

- A domain you control. It becomes public — it goes in the bridge line handed to users — and
  it will eventually be blocked somewhere, which is what happens to a bridge that works. Do
  not use a domain you need for anything else.
- A host whose provider permits Tor **bridge** relays. A bridge is not an exit node and
  attracts none of an exit's abuse reports, but confirm it rather than assume it.
- Port 443 reachable.

## Testing

```console
$ nix flake check
$ nix build .#checks.x86_64-linux.bridge -L
```

The test supplies its own self-signed certificate through `acme.enable = false`, since ACME
cannot run against a domain that does not exist outside the VM.

## Licence

MIT. See [LICENSE](LICENSE).
