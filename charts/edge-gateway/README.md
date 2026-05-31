# Edge gateway (WireGuard + port forward)

Homelab runs `wireguard-gateway` (WireGuard **client** `WG_HOMELAB_PEER_PLACEHOLDER`). A VPS runs WireGuard **server** `WG_VPS_PEER_PLACEHOLDER` and publishes game ports to the internet.

## Homelab (Kubernetes)

- `wg0.conf.example` → secret `wg-gateway-config` in `edge-gateway`
- `configmap.yml` → `gateway.sh` DNATs `wg0` → in-cluster Services

```bash
kubectl create secret generic wg-gateway-config -n edge-gateway \
  --from-file=wg0.conf=./wg0.conf
```

## VPS (persistent iptables + WireGuard)

**Do not rely only on `netfilter-persistent save`** for game forwarding. `wg-quick down/up` does not read that file; it runs `PostUp` / `PostDown` from `/etc/wireguard/wg0.conf`. Saving both causes duplicate rules on boot.

**Source of truth:** `/etc/wireguard/wg0.conf` + `/etc/wireguard/vps-forward.sh` (see `vps-wg0.conf.example`, `vps-forward.sh.example`).

Homelab `AllowedIPs = WG_VPS_PEER_PLACEHOLDER/32` — the VPS **must SNAT** forwarded traffic to `WG_VPS_PEER_PLACEHOLDER` before it enters the tunnel.

### One-time migration (while it works)

```bash
# 1. Backup (you already did this — keep ~/wg0-*.conf ~/iptables-*.rules)
sudo wg showconf wg0 > ~/wg0-$(date +%F).conf
sudo cp /etc/wireguard/wg0.conf ~/wg0.conf-$(date +%F)
sudo iptables-save > ~/iptables-$(date +%F).rules

# 2. Install hook script (edit WAN_IFACE inside if not eth0)
sudo cp vps-forward.sh.example /etc/wireguard/vps-forward.sh
sudo chmod 750 /etc/wireguard/vps-forward.sh

# 3. Merge into /etc/wireguard/wg0.conf (see vps-wg0.conf.example):
#    Table = off
#    PostUp   = /etc/wireguard/vps-forward.sh up
#    PostDown = /etc/wireguard/vps-forward.sh down

# 4. Cycle WG — PostDown removes rules, PostUp re-adds cleanly
sudo wg-quick down wg0
sudo wg-quick up wg0

# 5. Verify (expect ONE line each for 42420 DNAT/SNAT, 8089 + 8443 TAK DNAT, no duplicate FORWARD)
sudo iptables-save | grep -E '42420|8089|8443|31889|10\.8\.0'

# 6. netfilter-persistent: edit /etc/iptables/rules.v4 and DELETE game/TAK NAT/FORWARD
#    blocks if present, then optionally: sudo netfilter-persistent save
#    (so boot does not duplicate what PostUp already adds)
```

If `rules.v4` still contains old `42420` / `10.8.0` lines **and** `PostUp` adds them again, edit `/etc/iptables/rules.v4` and delete the duplicate NAT/FORWARD blocks, keeping UFW/Docker chains intact.

### Day-2 operations

| Action | Command |
|--------|---------|
| List WG | `sudo wg show` |
| List NAT | `sudo iptables -t nat -L -n -v \| grep 42420` |
| List forward | `sudo iptables -L DOCKER-USER -n -v` |
| Reload WG + rules | `sudo wg-quick down wg0 && sudo wg-quick up wg0` |
| Enable on boot | `sudo systemctl enable wg-quick@wg0` |

Adding another game: extend `forwards` in `configmap.yml` (homelab) and add matching DNAT/SNAT/FORWARD lines in `vps-forward.sh` (VPS).
