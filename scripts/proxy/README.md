# atlas dev-subdomain proxy

Host-side infrastructure that makes stable `https://<name>.your-domain.com` dev
subdomains work: a persistent named Cloudflare Tunnel + a host Caddy reverse
proxy.

**Bring your own domain.** Everything here is parameterized on a zone in
*your* Cloudflare account — any registrable domain whose nameservers point at
Cloudflare; the free plan covers all of it (tunnel, wildcard DNS, edge TLS).
The domain appears in exactly two configs and they must agree:

| Where | What |
|---|---|
| `~/atlas-secrets/cloudflare.env` on atlas | `CF_ZONE=<your domain>` + `CF_ZONE_ID` (zone Overview page) — read by `setup.sh` for the one-time cloud bootstrap |
| `~/.config/atlas/env` on the Mac | `ATLAS_DEV_DOMAIN=<the same domain>` — what the `atlas` CLI builds `<name>.<domain>` URLs from |

```
Cloudflare edge (TLS)                          ← *.your-domain.com is proxied here
      │  *.your-domain.com  CNAME  <tunnel-id>.cfargotunnel.com
      ▼
cloudflared.service  ── named tunnel "atlas", token auth, no config.yml ──┐
      │                                                                    │
      ▼  ingress: everything → http://localhost:8080                       │
caddy.service        ── plain HTTP :8080, admin API localhost:2019 ────────┘
      │  per-Host reverse_proxy routes, added/removed at runtime by the CLI
      ▼
dev containers       ── 127.0.0.1:<port>, docker --network host
```

TLS terminates at the Cloudflare edge, so every origin hop below it is plain
HTTP. Caddy never provisions a certificate (`automatic_https` disabled).

## Files

| File | Role |
|---|---|
| `../../proxy/caddy.json` | Base Caddy config: admin API on `localhost:2019`, one HTTP server `atlas` on `:8080`, `automatic_https` off, **empty route list**. Runtime routes are added by the CLI. |
| `../../proxy/cloudflared-config.yml` | Ingress template for the *locally-managed* tunnel alternative (unused by the default token flow; needs a browser login). |
| `setup.sh` | One-time cloud bootstrap: create/reuse the named tunnel via the Cloudflare API, set its ingress to Caddy, write the wildcard DNS record, install the token, then call `install.sh`. Idempotent. |
| `install.sh` | Local systemd arm/refresh: install `caddy.json`, validate it, install + enable both units. Idempotent. |
| `caddy.service` | Host Caddy as a systemd service. |
| `cloudflared.service` | Named tunnel as a systemd service, token from `EnvironmentFile` (never argv). |

## How the CLI uses it (runtime contract)

`atlas dev --public` never touches Cloudflare. It only:

1. verifies Caddy admin is reachable — `curl -sf localhost:2019/config/`
2. verifies the tunnel is up — `systemctl is-active --quiet cloudflared`
3. upserts a per-Host route through the **admin API** (idempotent, `@id`-keyed):

```sh
# id scheme: atlas-web--<name>  (main)  |  atlas-web--<name>--<dns-branch>  (branch)
curl -sf -X DELETE http://localhost:2019/id/<id> >/dev/null 2>&1        # ignore 404
curl -sf -H 'Content-Type: application/json' \
     -X POST http://localhost:2019/config/apps/http/servers/atlas/routes \
     -d '{"@id":"<id>","match":[{"host":["<name>.your-domain.com"]}],
          "handle":[{"handler":"subroute","routes":[
            {"match":[{"path":["/_next/*","/__nextjs*"]}],
             "handle":[{"handler":"headers",
                        "request":{"delete":["Origin","Referer"]}}]},
            {"handle":[{"handler":"reverse_proxy",
                        "upstreams":[{"dial":"127.0.0.1:<port>"}]}]}]}]}'
```

The route is a **subroute**, not a bare reverse_proxy: its first sub-route
strips `Origin`/`Referer` on exactly Next.js' internal dev endpoints
(`/_next/*`, `/__nextjs*`) so HMR works with zero per-repo config, and it is
non-terminal, so every request falls through to the reverse_proxy — all other
paths proxy with their headers intact (CSRF unaffected).

`atlas dev stop` removes just that route (`DELETE /id/<id>`). The tunnel, Caddy,
and the wildcard DNS record are persistent infra and are never touched by the
CLI — only `setup.sh` manages them.

Because DNS is a **wildcard**, no per-project DNS record is ever created:
`<name>.your-domain.com` and `<name>-<branch>.your-domain.com` are already covered.

## Bring-up on atlas

```sh
# 0. install the binaries (see setup.sh header for the apt commands)
#    caddy + cloudflared

# 1. create the token file (0600 in a 0700 dir)
install -d -m700 ~/atlas-secrets
umask 077
cat > ~/atlas-secrets/cloudflare.env <<'EOF'
CLOUDFLARE_API_TOKEN=<token>
CF_ZONE_ID=<your-zone-id>
CF_ZONE=your-domain.com
# CF_ACCOUNT_ID=<optional; else resolved from the zone>
EOF

# 2. bootstrap everything
cd ~/atlas/scripts/proxy
./setup.sh

# 3. verify
systemctl is-active caddy cloudflared
curl -sf localhost:2019/config/ >/dev/null && echo 'caddy admin ok'
dig +short '*.your-domain.com' | grep cfargotunnel && echo 'wildcard ok'
```

To re-arm the units after editing `caddy.json` or a `.service` file (without
re-touching Cloudflare): `./install.sh`.

## Required Cloudflare API token permissions

The token lives only on atlas at `~/atlas-secrets/cloudflare.env` (0600) and is
read **only** by `setup.sh` — `atlas doctor` checks just that the file exists,
and its wildcard-DNS check is a plain `dig` that never touches the token.
Steady-state `atlas dev --public` needs no token.

| Scope | Permission | Why | Status |
|---|---|---|---|
| Zone `your-domain.com` | **DNS → Edit** | create/update the wildcard CNAME | confirmed present |
| Zone `your-domain.com` | **Zone → Read** | resolve zone id → account id (skip by setting `CF_ACCOUNT_ID`) | add if `CF_ACCOUNT_ID` unset |
| Account (owner of the zone) | **Cloudflare Tunnel → Edit** | create the tunnel, set ingress, read its run token | **likely missing — grant this** |

Grant the tunnel permission at
<https://dash.cloudflare.com/profile/api-tokens> → edit the token → add a line
**Account → Cloudflare Tunnel → Edit** scoped to your account → Save. A 403 /
error code `10000` on tunnel creation means this permission is absent.

## No browser login

The default flow is a **remotely-managed** tunnel: `setup.sh` creates it over the
API and cloudflared runs with `tunnel run` reading `TUNNEL_TOKEN` from
`/etc/atlas/cloudflared.env`. Ingress lives in Cloudflare — there is no
`config.yml` or credentials JSON on disk, and **no interactive login**.

The only path that needs a browser login is the locally-managed alternative
(`cloudflared tunnel create atlas` to mint `~/.cloudflared/cert.pem`); use
`proxy/cloudflared-config.yml` if you deliberately choose it. Not required here.

## Docker alternative to the systemd units

If you prefer containers over host processes, run the same two pieces in Docker.
The tunnel token still comes from `/etc/atlas/cloudflared.env`; Caddy still needs
its admin API reachable at `localhost:2019` (host networking keeps the CLI's
`ssh atlas curl localhost:2019` contract intact):

```sh
# Caddy — host networking so :8080 and the loopback dev upstreams work as-is
docker run -d --name atlas-caddy --restart unless-stopped --network host \
  -v /etc/atlas/caddy.json:/etc/caddy/caddy.json:ro \
  caddy:2 caddy run --config /etc/caddy/caddy.json

# cloudflared — token from the env file, never argv
docker run -d --name atlas-cloudflared --restart unless-stopped --network host \
  --env-file /etc/atlas/cloudflared.env \
  cloudflare/cloudflared:latest tunnel --no-autoupdate run
```

Run `setup.sh` up to the "arm systemd units" step for the cloud side, then start
these containers instead of `install.sh`. `atlas doctor` checks
`systemctl is-active cloudflared`; in the Docker variant point its tunnel check
at `docker inspect -f '{{.State.Running}}' atlas-cloudflared` instead.

## Security notes

- **Caddy admin API is localhost-only** (`localhost:2019`); it is never exposed
  to the LAN or the tunnel. The CLI reaches it over the existing `ssh atlas`
  multiplexed connection.
- **The Cloudflare token stays 0600** in a 0700 dir and never appears in argv —
  `setup.sh` passes it to curl via a 0600 config file, and the tunnel token
  reaches cloudflared through `EnvironmentFile`, not the command line.
- **Every value the CLI interpolates** into an admin-API request (`@id`, Host
  label, upstream port) is validated (`valid_name`, host-label regex
  `^[a-z0-9-]{1,63}$`, `u16`) before the JSON is assembled.
- **No destructive op without a guard**: `setup.sh` reuses an existing tunnel /
  DNS record rather than recreating it, and route deletes ignore 404.
