/**
 * server.ts — the ConusAI release host.
 *
 * Serves the installer, the release artifacts, and the channel pointers that
 * `install.sh` resolves. Replaces GitHub Releases + GitHub Pages for
 * distribution; the binaries themselves are built elsewhere (scripts/release
 * in the conusai-cloud repo) and uploaded here.
 *
 * ZERO DEPENDENCIES, deliberately. This process is the last hop before a
 * `curl … | bash` that runs as root on someone's server. Every package added
 * here is a package that could replace the bytes it hands out, so there are
 * none: only Bun's standard library.
 *
 * MODES
 *   origin  accepts authenticated uploads; this is the public release host.
 *   mirror  serves only. The write routes are NOT REGISTERED — a mirror
 *           returns 404 for them, not 401, because "this endpoint does not
 *           exist here" is the truth and leaks nothing about the origin.
 */
import { serve } from "bun";
import { timingSafeEqual } from "node:crypto";
import { rename, stat } from "node:fs/promises";
import { mkdir } from "node:fs/promises";
import {
  DATA_DIR, TARGETS, CHANNEL_NAMES,
  ensureDirs, releasePath, listPublishedReleases, readManifest, writeManifest,
  readChannel, writeChannel, fileExists, removeRelease, sha256File,
  validTag, validFile, validChannel,
  type Manifest, type ManifestFile,
} from "./storage.ts";
import { renderIndex, renderNotFound } from "./views.ts";

const PORT = Number(process.env.PORT ?? 3000);
const MODE = (process.env.MODE ?? "origin") as "origin" | "mirror";
const TOKEN = process.env.CONUSAI_PUBLISH_TOKEN ?? "";
const PUBLIC_URL = (process.env.PUBLIC_URL ?? "").replace(/\/$/, "");
const MAX_UPLOAD_BYTES = Number(process.env.MAX_UPLOAD_BYTES ?? 512 * 1024 * 1024);

// ---------------------------------------------------------------- startup ---
if (MODE !== "origin" && MODE !== "mirror") {
  console.error(`FATAL: MODE must be "origin" or "mirror" (got ${MODE})`);
  process.exit(1);
}

// Fail closed. A release host that boots without a token is a release host
// anyone can publish to, and it would look perfectly healthy while doing it.
// Refusing to start is loud; starting unauthenticated is silent.
if (MODE === "origin" && TOKEN.length < 32) {
  console.error(
    "FATAL: CONUSAI_PUBLISH_TOKEN must be set and at least 32 characters in origin mode.\n" +
    "       Generate one with:  openssl rand -hex 32\n" +
    "       (Set MODE=mirror to run a read-only mirror with no upload path.)",
  );
  process.exit(1);
}

await ensureDirs();

// ------------------------------------------------------------------ auth ---
/**
 * Constant-time comparison. A naive `===` on secrets leaks their prefix
 * through response timing; the lengths are compared first because
 * timingSafeEqual throws on a length mismatch.
 */
function authorized(req: Request): boolean {
  const header = req.headers.get("authorization") ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  const a = Buffer.from(presented);
  const b = Buffer.from(TOKEN);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

// --------------------------------------------------------------- helpers ---
const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });

const text = (body: string, status = 200, headers: Record<string, string> = {}) =>
  new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...headers },
  });

const err = (status: number, message: string) => json({ ok: false, error: message }, status);

const isPrerelease = (tag: string) => tag.includes("-");

function baseUrl(req: Request): string {
  if (PUBLIC_URL) return PUBLIC_URL;
  // Behind Traefik the request URL is the internal one; trust the forwarded
  // headers it sets, and fall back to the Host header.
  const proto = req.headers.get("x-forwarded-proto") ?? "https";
  const host = req.headers.get("x-forwarded-host") ?? req.headers.get("host") ?? "localhost";
  return `${proto}://${host}`;
}

/** GitHub-releases-shaped, so `conusai upgrade` can later switch hosts by
 *  changing one constant instead of its parsing. */
function asGitHubRelease(m: Manifest, base: string) {
  return {
    tag_name: m.tag,
    name: m.tag,
    prerelease: isPrerelease(m.tag),
    draft: false,
    published_at: m.published_at,
    html_url: `${base}/#${m.tag}`,
    assets: m.files
      .filter((f) => f.name !== "manifest.json")
      .map((f) => ({
        name: f.name,
        browser_download_url: `${base}/releases/${m.tag}/${f.name}`,
        size: f.size,
        content_type: "application/octet-stream",
      })),
  };
}

/**
 * Serve a stored artifact. Range support matters here: these are 120–135 MB
 * tarballs, and without it a connection dropped at 90% restarts at zero.
 */
async function serveArtifact(req: Request, path: string, cacheControl: string): Promise<Response> {
  if (!(await fileExists(path))) return err(404, "not found");
  const file = Bun.file(path);
  const size = file.size;
  const range = req.headers.get("range");

  const headers: Record<string, string> = {
    "content-type": "application/octet-stream",
    "cache-control": cacheControl,
    "accept-ranges": "bytes",
    "x-content-type-options": "nosniff",
  };

  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (m) {
      const start = m[1] ? Number(m[1]) : 0;
      const end = m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
      if (Number.isFinite(start) && start <= end && start < size) {
        return new Response(file.slice(start, end + 1), {
          status: 206,
          headers: { ...headers, "content-range": `bytes ${start}-${end}/${size}` },
        });
      }
      return new Response(null, { status: 416, headers: { "content-range": `bytes */${size}` } });
    }
  }
  return new Response(file, { headers });
}

/** The installer that belongs to the current stable release, falling back to
 *  the newest published one while no stable channel exists yet. Serving a
 *  beta's installer to a default `curl | bash` would be a channel violation. */
async function resolveInstaller(): Promise<string | null> {
  const stable = await readChannel("stable");
  if (stable && (await fileExists(releasePath(stable, "install.sh")))) {
    return releasePath(stable, "install.sh");
  }
  for (const m of await listPublishedReleases()) {
    const p = releasePath(m.tag, "install.sh");
    if (await fileExists(p)) return p;
  }
  return null;
}

// -------------------------------------------------------------- finalize ---
/**
 * Turn a directory of uploaded bytes into a published release.
 *
 * The host re-computes every checksum against what it actually stored rather
 * than trusting the uploader's .sha256 — that file arrived over the same
 * connection as the tarball, so on its own it proves only that the uploader
 * was self-consistent.
 */
async function finalize(tag: string): Promise<Response> {
  const dir = releasePath(tag);
  let entries: string[];
  try {
    entries = [...(await Array.fromAsync(new Bun.Glob("*").scan({ cwd: dir })))];
  } catch {
    return err(404, `no uploaded files for ${tag}`);
  }
  if (entries.length === 0) return err(400, `no uploaded files for ${tag}`);
  if (!entries.includes("install.sh")) {
    return err(400, "refusing to finalize: install.sh was not uploaded");
  }

  const files: ManifestFile[] = [];
  const verifiedTargets: string[] = [];

  for (const name of entries.sort()) {
    if (name === "manifest.json") continue;
    const p = releasePath(tag, name);
    const st = await stat(p);
    if (!st.isFile()) continue;
    const digest = await sha256File(p);
    files.push({ name, size: st.size, sha256: digest });

    if (name.endsWith(".tar.gz")) {
      const sumFile = releasePath(tag, `${name}.sha256`);
      if (!(await fileExists(sumFile))) {
        return err(400, `refusing to finalize: ${name} has no .sha256`);
      }
      const claimed = (await Bun.file(sumFile).text()).match(/[0-9a-f]{64}/i)?.[0]?.toLowerCase();
      if (claimed !== digest) {
        return err(
          400,
          `checksum mismatch for ${name}: stored bytes hash to ${digest}, .sha256 claims ${claimed ?? "<unparsable>"}`,
        );
      }
      // A signature is required. The upload path is authenticated, but a
      // token is a bearer credential; the signature is what ties these bytes
      // to a key that never leaves the release engineer's machine.
      if (!(await fileExists(releasePath(tag, `${name}.minisig`)))) {
        return err(400, `refusing to finalize: ${name} has no .minisig`);
      }
      const t = /^conusai-(.+)\.tar\.gz$/.exec(name)?.[1];
      if (t) verifiedTargets.push(t);
    }
  }

  if (verifiedTargets.length === 0) {
    return err(400, "refusing to finalize: no platform tarballs present");
  }

  const complete = TARGETS.every((t) => verifiedTargets.includes(t));
  const manifest: Manifest = {
    tag,
    published_at: new Date().toISOString(),
    targets: verifiedTargets.sort(),
    complete,
    files,
  };
  await writeManifest(tag, manifest);

  return json({
    ok: true,
    tag,
    complete,
    targets: manifest.targets,
    missing: TARGETS.filter((t) => !verifiedTargets.includes(t)),
    verified: files.filter((f) => f.name.endsWith(".tar.gz")).length,
  });
}

// ---------------------------------------------------------------- routing ---
async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const path = decodeURIComponent(url.pathname);
  const seg = path.split("/").filter(Boolean);
  const base = baseUrl(req);

  // Named, always-defined views of the path segments.
  //
  // `noUncheckedIndexedAccess` is on, and it should be: this router indexes an
  // array built from network input, which is exactly the case that flag exists
  // for. Rather than assert the indexes away, absent segments become "" -- a
  // value every validator below (validTag / validFile / validChannel) rejects.
  // Structure is still enforced by the seg.length checks on each route.
  const s0 = seg[0] ?? "";
  const s1 = seg[1] ?? "";
  const s2 = seg[2] ?? "";
  const s3 = seg[3] ?? "";

  // Reject traversal EXPLICITLY, before routing.
  //
  // The per-segment validators in storage.ts already make a traversal
  // unrepresentable, and a percent-encoded "../.." additionally fails to match
  // any route because it changes the segment count. But both of those are
  // incidental defences: they reject the request as a side effect of not
  // matching, not because anyone decided to. On the one endpoint in this
  // service that turns network input into a filesystem path, the rejection
  // should be the stated intent, so it stays true if the routes are ever
  // reshaped.
  if (seg.includes("..") || seg.includes(".") || path.includes("\0")) {
    return err(400, "invalid path");
  }

  if (path === "/healthz") return text("ok\n");

  // ---- writes (origin only) ------------------------------------------------
  if (MODE === "origin" && path.startsWith("/api/")) {
    const needsAuth =
      req.method === "PUT" || req.method === "POST" || req.method === "DELETE";
    if (needsAuth && !authorized(req)) {
      return new Response(JSON.stringify({ ok: false, error: "unauthorized" }), {
        status: 401,
        headers: {
          "content-type": "application/json",
          "www-authenticate": 'Bearer realm="conusai-release"',
        },
      });
    }

    // PUT /api/releases/:tag/:file
    if (req.method === "PUT" && s0 === "api" && s1 === "releases" && seg.length === 4) {
      const tag = s2;
      const name = s3;
      if (!validTag(tag)) return err(400, "invalid tag");
      if (!validFile(name)) return err(400, "invalid filename");

      // Releases are immutable. Re-publishing a tag with different bytes is
      // the supply-chain failure this design exists to prevent, so a finalized
      // release is closed unless the caller is explicit.
      if ((await readManifest(tag)) && req.headers.get("x-conusai-force") !== "true") {
        return err(409, `${tag} is already published (send X-Conusai-Force: true to replace)`);
      }

      const declared = Number(req.headers.get("content-length") ?? "0");
      if (declared > MAX_UPLOAD_BYTES) return err(413, "upload too large");
      if (!req.body) return err(400, "empty body");

      await mkdir(releasePath(tag), { recursive: true });
      const finalPath = releasePath(tag, name);
      const tmpPath = `${finalPath}.part`;

      // Streamed with a running cap: Content-Length is a claim, not a limit,
      // and a chunked upload does not have to send one at all.
      const sink = Bun.file(tmpPath).writer();
      let written = 0;
      try {
        for await (const chunk of req.body as ReadableStream<Uint8Array>) {
          written += chunk.byteLength;
          if (written > MAX_UPLOAD_BYTES) {
            await sink.end();
            await removeFileQuiet(tmpPath);
            return err(413, "upload exceeded size limit");
          }
          sink.write(chunk);
        }
        await sink.end();
      } catch (e) {
        await Promise.resolve(sink.end()).catch(() => {});
        await removeFileQuiet(tmpPath);
        return err(500, `upload failed: ${(e as Error).message}`);
      }

      // Rename last, so a partial transfer never appears under its real name.
      await rename(tmpPath, finalPath);
      return json({ ok: true, tag, file: name, size: written });
    }

    // POST /api/releases/:tag/finalize
    if (req.method === "POST" && s0 === "api" && s1 === "releases" && s3 === "finalize") {
      if (!validTag(s2)) return err(400, "invalid tag");
      return finalize(s2);
    }

    // DELETE /api/releases/:tag
    if (req.method === "DELETE" && s0 === "api" && s1 === "releases" && seg.length === 3) {
      const tag = s2;
      if (!validTag(tag)) return err(400, "invalid tag");
      for (const c of CHANNEL_NAMES) {
        if ((await readChannel(c)) === tag) {
          return err(409, `${tag} is currently promoted to channel '${c}'; repoint it first`);
        }
      }
      await removeRelease(tag);
      return json({ ok: true, deleted: tag });
    }

    // POST /api/channels/:channel   (body: the tag)
    if (req.method === "POST" && s0 === "api" && s1 === "channels" && seg.length === 3) {
      const channel = s2;
      if (!validChannel(channel)) return err(400, "invalid channel");
      const tag = (await req.text()).trim();
      if (!validTag(tag)) return err(400, "invalid tag in body");

      const manifest = await readManifest(tag);
      if (!manifest) {
        return err(409, `${tag} is not published (upload and finalize it before promoting)`);
      }

      // The gate that matters. An incomplete release promoted to a channel
      // 404s install.sh on exactly the platforms it lacks — silently, until
      // someone tries to install there. That is how conusai/get served an
      // amd64-only build as `stable` while every workflow run showed green.
      if (!manifest.complete && req.headers.get("x-conusai-allow-partial") !== "true") {
        const missing = TARGETS.filter((t) => !manifest.targets.includes(t));
        return err(
          409,
          `${tag} is missing ${missing.join(", ")}. Promoting it would 404 install.sh on those platforms. ` +
            `Send X-Conusai-Allow-Partial: true only if that is genuinely intended.`,
        );
      }

      await writeChannel(channel, tag);
      return json({ ok: true, channel, tag, complete: manifest.complete });
    }
  }

  // ---- reads ---------------------------------------------------------------
  if (req.method !== "GET" && req.method !== "HEAD") {
    return err(405, "method not allowed");
  }

  if (path === "/" || path === "/index.html") {
    const releases = await listPublishedReleases();
    const channels: Record<string, string | null> = {};
    for (const c of CHANNEL_NAMES) channels[c] = await readChannel(c);
    return new Response(renderIndex({ releases, channels, base, mode: MODE }), {
      headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=60" },
    });
  }

  if (path === "/install.sh") {
    const p = await resolveInstaller();
    if (!p) return text("# no release published yet\nexit 1\n", 503);
    return new Response(Bun.file(p), {
      headers: {
        "content-type": "text/x-shellscript; charset=utf-8",
        // Never cached: this is how a fix reaches users.
        "cache-control": "no-store",
      },
    });
  }

  // /channels/:name — the pointer install.sh resolves. Must never be stale.
  if (s0 === "channels" && seg.length === 2) {
    if (!validChannel(s1)) return err(400, "invalid channel");
    const tag = await readChannel(s1);
    if (!tag) return err(404, `no release on channel '${s1}'`);
    return text(`${tag}\n`, 200, { "cache-control": "no-store" });
  }

  // /releases/:tag/:file — content-addressed by tag, so immutable.
  if (s0 === "releases" && seg.length === 3) {
    const tag = s1;
    const name = s2;
    if (!validTag(tag) || !validFile(name)) return err(400, "invalid path");
    if (!(await readManifest(tag))) return err(404, "release not published");
    return serveArtifact(req, releasePath(tag, name), "public, max-age=31536000, immutable");
  }

  if (path === "/api/releases") {
    const releases = await listPublishedReleases();
    return json(releases.map((m) => asGitHubRelease(m, base)), 200, {
      "cache-control": "public, max-age=60",
    });
  }

  if (path === "/api/releases/latest") {
    const stable = await readChannel("stable");
    const m = stable ? await readManifest(stable) : null;
    if (!m) return err(404, "no stable release");
    return json(asGitHubRelease(m, base), 200, { "cache-control": "no-store" });
  }

  if (path === "/conusai-logo.png") {
    const p = new URL("./conusai-logo.png", import.meta.url).pathname;
    if (await fileExists(p)) {
      return new Response(Bun.file(p), {
        headers: { "content-type": "image/png", "cache-control": "public, max-age=86400" },
      });
    }
  }

  return new Response(renderNotFound(base), {
    status: 404,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

async function removeFileQuiet(p: string): Promise<void> {
  try {
    await Bun.file(p).delete();
  } catch {
    /* already gone */
  }
}

serve({
  port: PORT,
  idleTimeout: 255, // large uploads over slow links must not be reaped
  maxRequestBodySize: MAX_UPLOAD_BYTES,
  async fetch(req) {
    try {
      return await handle(req);
    } catch (e) {
      // Never leak a path or stack to the network.
      console.error("request failed:", e);
      return err(500, "internal error");
    }
  },
});

console.log(
  `conusai release host listening on :${PORT}  mode=${MODE}  data=${DATA_DIR}` +
    (MODE === "mirror" ? "  (read-only: upload routes not registered)" : ""),
);
