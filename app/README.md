# ConusAI release host

Serves the installer, the release artifacts, and the channel pointers that
`install.sh` resolves. Replaces GitHub Releases + GitHub Pages for
*distribution*; binaries are built elsewhere (`scripts/release` in
`conusai-cloud`) and uploaded here.

Zero dependencies, deliberately: this process is the last hop before a
`curl … | bash` that runs as root.

## Why this is not hosted on ConusAI itself

A release host must not live inside the failure domain it recovers. If a bad
ConusAI release bricked the instance serving this, the channel needed to ship
the fix would be down with it, and the rollback artifact would be unreachable.
Running it on independent infrastructure keeps those failures uncorrelated.

## Deploying on Dokploy

| Setting | Value |
|---|---|
| Source | `conusai/get`, branch `main` (public — no deploy key) |
| Build type | Dockerfile |
| Build context | `app` |
| Dockerfile | `app/Dockerfile` |
| Port | `3000` |
| Volume mount | any named volume → `/data` |
| Auto deploy | on |

Environment:

| Variable | Required | Notes |
|---|---|---|
| `CONUSAI_PUBLISH_TOKEN` | yes (origin mode) | ≥32 chars: `openssl rand -hex 32`. The server **refuses to start** without it. |
| `PUBLIC_URL` | recommended | Absolute base URL; used in `/api/*` download links. |
| `MODE` | no | `origin` (default) or `mirror`. |
| `MAX_UPLOAD_BYTES` | no | Default 512 MiB. |

The volume must be mounted before the first publish — artifacts live there and
survive redeploys; the image holds only code.

## Modes

- **origin** — accepts authenticated uploads. The public release host.
- **mirror** — read-only. The upload routes are *not registered*, so they
  return 404 rather than 401: nothing about the origin is implied.

## Routes

Public: `/`, `/install.sh`, `/channels/{stable,beta,nightly}`,
`/releases/<tag>/<file>`, `/api/releases`, `/api/releases/latest`, `/healthz`.

Authenticated (`Authorization: Bearer $CONUSAI_PUBLISH_TOKEN`):

| Route | Purpose |
|---|---|
| `PUT /api/releases/<tag>/<file>` | Upload one artifact. 409 on a published tag unless `X-Conusai-Force: true`. |
| `POST /api/releases/<tag>/finalize` | Re-verify every checksum server-side, then publish. |
| `POST /api/channels/<ch>` | Move a channel pointer (body: the tag). |
| `DELETE /api/releases/<tag>` | Remove a release; refuses while it is promoted. |

`/api/releases` is GitHub-releases-shaped so `conusai upgrade` can switch hosts
by changing one constant.

## Invariants worth keeping

1. **A release without `manifest.json` does not exist.** An interrupted upload
   is invisible, not partially live.
2. **Finalize re-hashes stored bytes.** The uploader's `.sha256` arrived over
   the same connection as the tarball, so alone it proves only self-consistency.
3. **Signatures are mandatory at finalize.** The upload token is a bearer
   credential; the minisign key never leaves the release engineer's machine.
4. **Promoting an incomplete release requires `X-Conusai-Allow-Partial: true`.**
   An amd64-only build promoted to `stable` 404s `install.sh` on the other three
   platforms, silently. That has happened.
5. **`channels/*` is `no-store`; `releases/*` is immutable.** The channel
   pointer is how a fix reaches users.

## Testing

```bash
app/smoke-test.sh          # 26 checks, throwaway key and data dir
bunx tsc --noEmit          # strict, incl. noUncheckedIndexedAccess
```
