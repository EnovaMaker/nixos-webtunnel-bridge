{
  description = "nixos-webtunnel-bridge: a Tor WebTunnel bridge relay, declared once";

  inputs = {
    # Not a stable channel, and that is a finding rather than a preference.
    # webtunnel is absent from 24.05 and 24.11 entirely; 25.05 carries a git
    # snapshot from July 2024 and 25.11 carries 0.0.3, while upstream released
    # 0.0.5 in July 2026. No stable channel currently offers a current
    # transport, so a bridge built on one would ship a stale one.
    #
    # The lock file, not the channel name, is what makes this reproducible.
    # Getting a current webtunnel into a stable channel is real work and is
    # part of what the upstream milestone is for.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosModules.default = ./nixos/webtunnel-bridge.nix;
      nixosModules.webtunnel-bridge = ./nixos/webtunnel-bridge.nix;

      checks.${system} = {
        bridge = import ./tests/bridge.nix { inherit pkgs; module = self.nixosModules.default; };
      };
    };
}
