# Tencent EdgeOne

OpenList on EdgeOne is **OpenList-Worker**, not this Go binary.

## One-click

| International | China |
| --- | --- |
| [![Deploy with EdgeOne](https://cdnstatic.tencentcs.com/edgeone/pages/deploy.svg)](https://edgeone.ai/pages/new?project-name=openlist-tsworker&repository-url=https://github.com/OpenListTeam/OpenList-Worker&install-command=pnpm%20install%20--no-frozen-lockfile&build-command=pnpm%20run%20build&output-directory=dist&env=ENCRYPTION_SECRET,JWT_SECRET) | [![Deploy with EdgeOne](https://cdnstatic.tencentcs.com/edgeone/pages/deploy.svg)](https://console.cloud.tencent.com/edgeone/pages/new?project-name=openlist-tsworker&repository-url=https://github.com/OpenListTeam/OpenList-Worker&install-command=pnpm%20install%20--no-frozen-lockfile&build-command=pnpm%20run%20build&output-directory=dist&env=ENCRYPTION_SECRET,JWT_SECRET) |

After deploy, set secrets in the Makers console:

- International: [console.edgeone.ai/makers](https://console.edgeone.ai/makers)
- China: [console.cloud.tencent.com/edgeone/makers](https://console.cloud.tencent.com/edgeone/makers)

Required:

- `JWT_SECRET`
- `ENCRYPTION_SECRET`

Optional:

- `ADMIN_PASSWORD`
- `CRON_SECRET` (EdgeOne schedule calls `/api/task/refresh`)

## What Blob / KV is for

On EdgeOne, Worker persistence auto-detects in this order: **Blob → KV REST / binding → memory**.

| Backend | How it is used |
| --- | --- |
| EdgeOne Blob (`DB_DRIVER=blob`) | Default and preferred. `@edgeone/pages-blob` is injected in Makers. Stronger consistency than KV. |
| EdgeOne KV (`DB_DRIVER=kv`) | Binding names `KV` / `EDGEONE_KV`. Same map/key JSON format as Cloudflare KV. |
| Memory | Last resort. Data is lost on cold start. Always bind Blob or KV. |

Same format flags as Cloudflare:

- `DB_FORMAT=map` — one JSON object (default, simplest)
- `DB_FORMAT=key` — one KV/Blob key per entity (safer as data grows)

Files still live on the mounted storages. Blob/KV only store OpenList metadata.

## Manual deploy

Import [OpenListTeam/OpenList-Worker](https://github.com/OpenListTeam/OpenList-Worker) as an EdgeOne Pages / Makers project.

Build settings (already in upstream `edgeone.json`):

- Install: `pnpm install --no-frozen-lockfile`
- Build: `pnpm run build`
- Output: `dist`
- Node: `22.21.1`

To use this fork's frontend during the EdgeOne build, add:

```text
FRONTEND_GIT_URL=https://github.com/v200dd/OpenList-Frontend.git
FRONTEND_GIT_REF=main
```

Confirm `/api/health` after the first deploy, then complete the wizard.

## EdgeOne in front of this Go binary

That is CDN / WAF only. The origin still needs Docker/VPS. EdgeOne KV/Blob cannot host `data/data.db` for the Go process.
