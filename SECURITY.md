# Security

CleanKaskad modifies packet forwarding and NAT rules. Test changes on a VPS with console access when possible.

The script only manages chains prefixed with `CK_` and does not intentionally flush unrelated firewall chains.

Do not publish private VPN keys or full client configurations when reporting a problem. An Endpoint alone does not contain a private key.
