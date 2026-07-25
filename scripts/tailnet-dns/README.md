# tailnet-dns — make the tailnet's DNS follow atlas' power state

atlas is an on-demand box: Wake-on-LAN up, powered down when it isn't needed.
That collides badly with running the tailnet's DNS filter (AdGuard Home) on it.

**The problem.** A Tailscale *global nameserver* is pushed to every device in
the tailnet unconditionally. Point it at AdGuard on atlas and every device —
laptop, phone — sends all DNS there, including while atlas is asleep. Queries
then go nowhere and the whole tailnet looks like it has no internet, even
though routing is perfectly fine and no exit node is in use.

**Why a second nameserver doesn't fix it.** Tailscale queries all global
nameservers *in parallel and takes the fastest answer* — it is not ordered
failover. Adding a public resolver as backup means it wins races whenever it is
quicker, so filtering silently degrades. You get resilience by giving up the
thing you installed AdGuard for.

**The fix here.** Let atlas publish itself as the tailnet resolver only while it
is actually running, using the Tailscale API:

| atlas | global nameserver | devices resolve via |
|---|---|---|
| running | its own tailnet IP (AdGuard) | AdGuard — filtered, tailnet-wide |
| off / asleep | *(none)* | their own DNS (router, carrier) |

Both transitions are automatic and need no client-side configuration.
MagicDNS (`*.ts.net`) is unaffected either way — it never depended on the
global nameserver.

## Install

On the box running AdGuard:

```bash
sudo install -m755 atlas-tailnet-dns /usr/local/bin/atlas-tailnet-dns
sudo cp atlas-tailnet-dns.service /etc/systemd/system/

sudo install -m600 /dev/null /etc/atlas-tailnet-dns.env
sudo tee /etc/atlas-tailnet-dns.env >/dev/null <<'EOF'
# Preferred: an OAuth client (Tailscale admin → Settings → OAuth clients,
# scope "dns" with write). OAuth clients do not expire.
TS_CLIENT_ID=...
TS_CLIENT_SECRET=tskey-client-...
# Alternative: a plain API access token — note these DO expire (90 days max),
# after which the tailnet silently stops following atlas.
# TS_API_KEY=tskey-api-...
ADGUARD_IP=100.x.y.z          # this box's tailnet IP, where AdGuard listens
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now atlas-tailnet-dns
```

`systemctl enable` is what arms the shutdown half: systemd runs `ExecStop`
(→ clear) when the unit stops during shutdown, and `ExecStart` (→ AdGuard) at
boot. Check the current published value any time with
`sudo atlas-tailnet-dns status`.

## Notes

- **Startup ordering matters.** `up` waits (up to 60 s) for AdGuard to actually
  answer a query before publishing it, so devices are never pointed at a
  resolver that is still starting. It also retries the API call, since internet
  access can lag the unit at boot.
- **Credentials stay out of git.** The token lives only in
  `/etc/atlas-tailnet-dns.env` (root, `0600`).
- **Prefer OAuth over an API token.** Access tokens expire (90 days max, and
  the admin console offers far shorter ones); when one lapses `down` fails at
  shutdown and the tailnet is left pointing at a box that is powering off —
  exactly the failure this script exists to prevent. OAuth client credentials
  do not expire; the script exchanges them for a short-lived access token per
  run. Neither can be created through the API — both come from the admin
  console.
- **Ungraceful power loss** (yanked cord, kernel panic) skips `ExecStop`, so the
  nameserver stays pointed at a box that is gone until it next boots. A normal
  `shutdown`/`reboot` is fully covered.
