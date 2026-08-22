/**
 * views.ts — server-rendered HTML. No client framework, no bundler, no build
 * step: the pages are a heading, a command, and a table. Shipping a SPA to
 * render a list of files would add a toolchain to the one service that most
 * needs to stay auditable.
 *
 * Palette matches the existing conusai/get landing page so the cutover is not
 * a visual change.
 */
import type { Manifest } from "./storage.ts";
import { TARGETS } from "./storage.ts";

/** Everything user-controlled goes through here before reaching the page. */
function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(0)} KB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${(bytes / 1024 ** 3).toFixed(2)} GB`;
}

function fmtDate(iso: string): string {
  return iso.slice(0, 10);
}

const STYLE = `
  :root {
    --bg: #0a0f0e; --panel: #101817; --panel-2: #0c1413; --line: #1e2a28;
    --fg: #e8f0ee; --muted: #9ab3ae; --accent: #57b3aa; --accent-bright: #80cdc6;
    --warn: #e0a458;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  .wrap { max-width: 880px; margin: 0 auto; padding: 3rem 1.25rem 5rem; }
  h1 { font-size: 1.9rem; line-height: 1.25; margin: 0 0 .5rem; letter-spacing: -.02em; }
  h2 { font-size: 1.05rem; margin: 2.5rem 0 .75rem; color: var(--accent-bright); font-weight: 600; }
  p.lede { color: var(--muted); margin: 0 0 2rem; }
  code, pre, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  .cmd {
    background: var(--panel-2); border: 1px solid var(--line); border-radius: 8px;
    padding: .9rem 1rem; overflow-x: auto; white-space: nowrap;
    color: var(--accent-bright); font-size: .9rem;
  }
  .cmd .p { color: var(--muted); user-select: none; }
  table { width: 100%; border-collapse: collapse; font-size: .9rem; }
  th, td { text-align: left; padding: .55rem .6rem; border-bottom: 1px solid var(--line); }
  th { color: var(--muted); font-weight: 500; font-size: .78rem; text-transform: uppercase; letter-spacing: .06em; }
  td.tag { font-family: ui-monospace, monospace; color: var(--accent-bright); white-space: nowrap; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { color: var(--accent-bright); text-decoration: underline; }
  .pill {
    display: inline-block; padding: .08rem .5rem; border-radius: 999px;
    font-size: .72rem; border: 1px solid var(--line); color: var(--muted);
    background: var(--panel);
  }
  .pill.stable { color: var(--accent-bright); border-color: var(--accent); }
  .pill.partial { color: var(--warn); border-color: var(--warn); }
  .files { color: var(--muted); font-size: .82rem; }
  .files a { margin-right: .6rem; white-space: nowrap; }
  footer { margin-top: 3.5rem; color: var(--muted); font-size: .82rem;
           border-top: 1px solid var(--line); padding-top: 1.25rem; }
  .empty { color: var(--muted); background: var(--panel); border: 1px dashed var(--line);
           border-radius: 8px; padding: 1.5rem; text-align: center; }
`;

function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>${STYLE}</style>
</head><body><div class="wrap">${body}</div></body></html>`;
}

export function renderIndex(opts: {
  releases: Manifest[];
  channels: Record<string, string | null>;
  base: string;
  mode: string;
}): string {
  const { releases, channels, base, mode } = opts;

  const channelRows = Object.entries(channels)
    .map(([name, tag]) => {
      const value = tag
        ? `<a href="/releases/${esc(tag)}/conusai-linux-amd64.tar.gz">${esc(tag)}</a>`
        : `<span class="files">none</span>`;
      return `<tr><td class="tag">${esc(name)}</td><td>${value}</td></tr>`;
    })
    .join("\n");

  const releaseRows = releases
    .map((m) => {
      const promoted = Object.entries(channels)
        .filter(([, t]) => t === m.tag)
        .map(([c]) => `<span class="pill stable">${esc(c)}</span>`)
        .join(" ");
      const missing = TARGETS.filter((t) => !m.targets.includes(t));
      const partial = missing.length
        ? ` <span class="pill partial" title="missing ${esc(missing.join(", "))}">partial</span>`
        : "";
      const links = m.files
        .filter((f) => f.name.endsWith(".tar.gz"))
        .map(
          (f) =>
            `<a href="/releases/${esc(m.tag)}/${esc(f.name)}" title="${fmtSize(f.size)}">${esc(
              f.name.replace(/^conusai-|\.tar\.gz$/g, ""),
            )}</a>`,
        )
        .join("");
      return `<tr id="${esc(m.tag)}">
  <td class="tag">${esc(m.tag)}</td>
  <td>${fmtDate(m.published_at)}</td>
  <td>${promoted}${partial}</td>
  <td class="files">${links}</td>
</tr>`;
    })
    .join("\n");

  const table = releases.length
    ? `<table>
  <thead><tr><th>Version</th><th>Published</th><th>Channel</th><th>Downloads</th></tr></thead>
  <tbody>${releaseRows}</tbody>
</table>`
    : `<div class="empty">No releases published yet.</div>`;

  return page(
    "ConusAI Cloud — Install",
    `
<h1>Install ConusAI Cloud</h1>
<p class="lede">Self-hosted PaaS. One command, any Linux or macOS host.</p>

<div class="cmd"><span class="p">$ </span>curl -fsSL ${esc(base)}/install.sh | bash</div>

<h2>Channels</h2>
<table><tbody>${channelRows}</tbody></table>
<p class="files">Install a prerelease with
<code>curl -fsSL ${esc(base)}/install.sh | bash -s -- --channel beta</code></p>

<h2>Release history</h2>
${table}

<footer>
  Every artifact is published with a SHA-256 checksum and a minisign signature;
  the installer verifies both and refuses to install on a mismatch.
  <br>Serving from a ${esc(mode)} host.
</footer>`,
  );
}

export function renderNotFound(base: string): string {
  return page(
    "Not found — ConusAI Cloud",
    `<h1>404</h1>
<p class="lede">No such release, channel, or file.</p>
<div class="cmd"><span class="p">$ </span>curl -fsSL ${esc(base)}/install.sh | bash</div>
<p class="files"><a href="/">All releases</a></p>`,
  );
}
