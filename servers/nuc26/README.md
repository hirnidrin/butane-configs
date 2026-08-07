# nuc26: WireGuard VPN gateway

Plain Fedora CoreOS, no rebase. Built with `make nuc26` from the repo root — see the
[main README](../../README.md) for the build and deployment steps.

* Static WireGuard endpoint in the LAN, with a webadmin for client config management.
* Simple, efficient and free alternative to corporate VPN server solutions.

Notes

* WireGuard listens on UDP port 51820 for incoming road warrior connections
  * Set up port forwarding: firewall WAN port 51820 -> nuc26 LAN IP address, port 51820
* The wg-easy webadmin listens on the nuc26 LAN IP address, port 8443 — don't expose this to the WAN
  * `https://<nuc26-ip>:8443`
  * TLS is terminated by a `caddy` reverse proxy with a self-signed cert; wg-easy's own webadmin
    port is published to localhost only, and port 51821 redirects to the secure port
* After initial setup, open the webadmin and
  * run the config steps
  * Change the default legacy `iptables`-based **PostUp** and **PostDown** hooks to `nftables`, see [wg-easy documentation](https://wg-easy.github.io/wg-easy/latest/examples/tutorials/podman-nft/#edit-hooks)
  * Reboot -> ready for setting up road warrior client configs.
