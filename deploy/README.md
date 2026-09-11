# Deploy OpenList to Cloudflare and EdgeOne

This Go repository (`v200dd/OpenList`) is a long-running process with local SQLite, a `data/` directory, logs, and background tasks. **It cannot run as-is on Cloudflare Workers or Tencent EdgeOne Functions.** Those platforms are short-lived and have no local disk.

Use the official TypeScript rewrite instead:

- Source: [OpenListTeam/OpenList-Worker](https://github.com/OpenListTeam/OpenList-Worker)
- Docs: [Worker installation](https://doc.oplist.org/guide/installation/worker)

That Worker already persists config through **Cloudflare KV / D1 / Durable Objects** and **EdgeOne Blob / KV**.

| Goal | Use this |
| --- | --- |
| Full OpenList on the edge, with KV/Blob as the database | [OpenList-Worker](https://github.com/OpenListTeam/OpenList-Worker) |
| Keep this Go binary, put CDN/WAF in front | Reverse proxy only. KV is unused. |
| Speed up / hide origin download URLs | [OpenList-Proxy](https://github.com/OpenListTeam/OpenList-Proxy) (download proxy, not the app) |

This fork builds the UI from [v200dd/OpenList-Frontend](https://github.com/v200dd/OpenList-Frontend). Point Worker builds at the same frontend with:

```bash
FRONTEND_GIT_URL=https://github.com/v200dd/OpenList-Frontend.git
FRONTEND_GIT_REF=main
```

- [Cloudflare Workers](./cloudflare.md)
- [Tencent EdgeOne](./edgeone.md)
