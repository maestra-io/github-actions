# maestra.infra.wireguard_burst

WireGuard termination for Kubernetes burst nodes outside the private network
(issues-maestra#1444). Each burst node peers with **two** gateways; every slot
address is a BFD-tracked FRR static `/32` through the tunnel, so a slot's route
exists only while BFD (300 ms x 3) over that tunnel is up and a dead tunnel is
withdrawn in under a second.

## Modes

| | `embedded` | `dedicated` |
|---|---|---|
| Host | also something else (a NAT gateway) | does only this |
| Tunnel, key, peer sync, key assert, metrics | role | role |
| `/etc/nftables.conf` | consumer, includes `wireguard_burst_nft_*` | role |
| WAN leg (netplan, source-routed table), LAN MTU | consumer | role |
| `/etc/frr/frr.conf`, `daemons` | consumer, includes `wireguard_burst_frr_*` | role (FRR from deb.frrouting.org) |
| A dead tunnel | slot falls back to the neighbour gateway on the LAN, then a blackhole | slot `/32` withdrawn from eBGP; the uplinks use the other gateway |
| Sysctls | consumer (`rp_filter` 0 on the tunnel, see below) | role (`ip_forward`, `rp_filter` 2, L4 multipath hash) |

## Inputs

All in `defaults/main.yml` with comments. Required:

- `wireguard_burst_address`: this host's tunnel address (`/32`, no prefix length).
- `wireguard_burst_slots`: `[{name, ip, pubkey}]`, the slot pool; `pubkey` is the
  slot's public key, the private half goes to the VM that takes the slot.
- dedicated: `wireguard_burst_bgp_router_id`, `wireguard_burst_bgp_uplinks`
  (`[{address, remote_asn, description?}]`), `wireguard_burst_bgp_accept`
  (prefix-list entries taken from the uplinks); usually also
  `wireguard_burst_static_routes` (e.g. the LAN aggregate via its gateway).
- embedded with a fallback: `wireguard_burst_neighbour_lan_ip` and
  `wireguard_burst_neighbour_mac` (LAN interface: `wireguard_burst_lan_interface`).

Recommended: `wireguard_burst_gateway_pubkeys` (`{inventory_hostname: pubkey}`) and
`wireguard_burst_pubkey_consumer_hint` (where the burst nodes take the keys from).

## Outputs (embedded mode)

Facts set by the role, newline-separated text. Run the role **before** the
consumer templates its files:

```jinja
{# frr.conf, top level #}
{{ wireguard_burst_frr_static }}
bfd
{{ wireguard_burst_frr_bfd }}
exit
```

```jinja
{# nftables.conf, table inet filter #}
chain input {   # policy drop
  {{ wireguard_burst_nft_input }}
}
chain forward {
  {{ wireguard_burst_nft_forward }}
}
```

`wireguard_burst_manage_interface: false` leaves the interface to the consumer
(e.g. netplan) with the same key file `/etc/wireguard/<interface>.key`.

## Design notes

- **The slot route bootstraps itself.** The static is `onlink` on the tunnel,
  so bfdd sends on the tunnel interface before the route exists (the kernel
  treats an interface-bound destination with no route as on-link).
- **No routing blackhole on a dedicated gateway.** A blackhole for a source
  fails `rp_filter`, which would drop the BFD packets that bring the slot up.
  Fail-closed is the forward chain: nothing is forwarded to or from the WAN
  interface. Embedded mode does use per-slot blackholes, so the consumer must
  keep `rp_filter` off on the tunnel (`all` and the interface; the effective
  value is the max of the two).
- **Embedded fallback loop.** With both tunnels down each gateway's fallback
  points at the other. `wireguard_burst_nft_forward` drops a slot packet that
  arrived from the neighbour's MAC and would leave towards it again.
- **No graceful restart (dedicated).** A rebooting gateway's slots disappear
  from its uplinks when BFD drops, instead of staying as stale routes for the
  restart time.
- **networkd vs zebra.** Dedicated mode sets `ManageForeignRoutes=no` so a
  networkd reload never removes zebra's routes.
- **Peers are synced live** with `wg set`: networkd reads the peer list only
  when it creates the device, and restarting networkd on a VRRP gateway drops
  its VIPs.

## Rotating a gateway key

The burst nodes carry each gateway's public key. A rebuilt gateway generates a
new key and the play stops at the assert (old and new key in the message).
Either restore the old `/etc/wireguard/<interface>.key`, or rotate in this
order: update `wireguard_burst_gateway_pubkeys` **and** the burst-node side
(`wireguard_burst_pubkey_consumer_hint`) in one change, run the play, restart
whatever renders the burst-node config, and re-create the running burst nodes
(their config is rendered once at boot).

## Rotating a slot key

Only for a slot no node holds: new key pair, private half where the burst-node
provisioning reads it, public half into `wireguard_burst_slots`, run the play
(the live peer set follows without a restart).

## Metrics

`<textfile_dir>/wireguard_burst.prom`, every `wireguard_burst_metrics_interval`:
`wireguard_peer_latest_handshake_seconds`, `wireguard_peer_rx_bytes`,
`wireguard_peer_tx_bytes`, labels `interface`, `slot`. BFD session state comes
from frr_exporter's bfd collector (`frr_bfd_peer_state`).
