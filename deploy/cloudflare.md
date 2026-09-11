# Cloudflare Workers

OpenList on Cloudflare is **OpenList-Worker**, not this Go binary.

## One-click

[![Deploy to Cloudflare Workers](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/OpenListTeam/OpenList-Worker)

If the button fails, fork [OpenListTeam/OpenList-Worker](https://github.com/OpenListTeam/OpenList-Worker) first, then deploy from your fork.

## What KV is for

Worker stores settings, users, storages, and share metadata in KV when `DB_FORMAT=map` (default) or `DB_FORMAT=key`.

| `DB_DRIVER` | Storage | When to use |
| --- | --- | --- |
| `auto` (default) | blob → cfkv → kv → d1 → memory | Leave this unless you need a specific backend |
| `kv` | Cloudflare KV **binding** | Simplest CF persistence. Enable `[[kv_namespaces]]` |
| `cfkv` | Cloudflare KV **REST API** | No Worker binding; needs `CF_ACCOUNT_ID`, `CF_KV_NAMESPACE_ID`, `CF_API_TOKEN` |
| `d1` | Cloudflare D1 (SQLite) | Better if you want SQL tables (`DB_FORMAT=sql`) |
| `do` | Durable Objects SQLite | Strong consistency for a single tenant |

KV is eventually consistent and has a **25 MiB value limit**. `map` writes the whole JSON blob to one key, so it is fine for small sites. Switch to `key` (one record per entity) or D1 if the blob grows.

Files themselves stay on the mounted net disks / S3 / WebDAV. KV only stores OpenList metadata.

## Manual deploy

```bash
git clone https://github.com/OpenListTeam/OpenList-Worker.git
cd OpenList-Worker

# optional: use this fork's frontend
export FRONTEND_GIT_URL=https://github.com/v200dd/OpenList-Frontend.git
export FRONTEND_GIT_REF=main

pnpm install
npx wrangler login
pnpm run deploy
```

`pnpm run deploy` creates a KV namespace named `KV` if missing, fetches the frontend, and runs `wrangler deploy`. Wrangler 4.x can auto-provision the binding.

Uncomment this in `wrangler.toml` if automatic provisioning is not available:

```toml
[[kv_namespaces]]
binding = "KV"
```

Set secrets in the Worker dashboard (do not put them in git):

- `JWT_SECRET`
- `ENCRYPTION_SECRET` (encrypts storage tokens; strongly recommended)
- optional `ADMIN_PASSWORD`

After deploy, open `/api/health`. Then finish the install wizard.

## Cloudflare in front of this Go binary

That is CDN / reverse proxy only. The origin still needs a VPS/Docker with a writable `data/` volume. KV cannot replace `data/data.db`.

The README item “Cloudflare Workers proxy” refers to [OpenList-Proxy](https://github.com/OpenListTeam/OpenList-Proxy) for download acceleration. Cloudflare forbids using Workers as a long-term high-traffic proxy.
