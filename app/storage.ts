/**
 * storage.ts — every filesystem access the release host makes.
 *
 * This module exists as a boundary, not because the operations are complex.
 * Two things depend on it:
 *
 *   1. Path-traversal safety. A release host takes a tag and a filename from
 *      the network and turns them into a path. That is the single highest-risk
 *      operation in the service, so it happens in exactly one place
 *      (`releasePath`) and every caller goes through it.
 *   2. The origin/mirror split. A mirror serves the same tree but never writes
 *      it. Keeping reads and writes behind one module means mirror mode is a
 *      matter of not registering the write routes, not a fork.
 *
 * The filesystem IS the database. A release is a directory; a channel is a
 * one-line file. There is no schema to migrate and no Postgres to run on a box
 * that already hosts dozens of apps.
 */
import { mkdir, readdir, readFile, writeFile, rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";

export const DATA_DIR = process.env.CONUSAI_DATA_DIR ?? "/data";
const RELEASES = join(DATA_DIR, "releases");
const CHANNELS = join(DATA_DIR, "channels");

export const CHANNEL_NAMES = ["stable", "beta", "nightly"] as const;
export type Channel = (typeof CHANNEL_NAMES)[number];

/** The four platforms install.sh knows how to ask for. */
export const TARGETS = ["linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64"] as const;

/**
 * Accepted shapes. Both are anchored, length-capped, and exclude every
 * character that could escape the directory: no "/", no "\", and — because
 * "." is legal inside a version — no way to form ".." since the tag must start
 * with "v" followed by a digit, and a filename of ".." fails FILE_RE's
 * requirement of at least one alphanumeric character.
 */
const TAG_RE = /^v[0-9][0-9A-Za-z.+-]{0,62}$/;
const FILE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

export function validTag(tag: string): boolean {
  return TAG_RE.test(tag) && !tag.includes("..");
}

export function validFile(name: string): boolean {
  return FILE_RE.test(name) && !name.includes("..");
}

export function validChannel(c: string): c is Channel {
  return (CHANNEL_NAMES as readonly string[]).includes(c);
}

/**
 * The only place a network-supplied string becomes a path. Throws rather than
 * returning null so a caller cannot accidentally proceed on a falsy value.
 */
export function releasePath(tag: string, file?: string): string {
  if (!validTag(tag)) throw new Error(`invalid tag: ${tag}`);
  if (file === undefined) return join(RELEASES, tag);
  if (!validFile(file)) throw new Error(`invalid file: ${file}`);
  return join(RELEASES, tag, file);
}

export function channelPath(channel: string): string {
  if (!validChannel(channel)) throw new Error(`invalid channel: ${channel}`);
  return join(CHANNELS, channel);
}

export interface ManifestFile {
  name: string;
  size: number;
  sha256: string;
}

export interface Manifest {
  tag: string;
  published_at: string;
  /** Targets with a verified tarball present. */
  targets: string[];
  /**
   * True when all four platforms are present. A false here is why channel
   * promotion needs an explicit override: an incomplete release promoted to a
   * channel 404s install.sh on precisely the platforms it is missing, and does
   * so silently until someone tries to install there.
   */
  complete: boolean;
  files: ManifestFile[];
}

export async function ensureDirs(): Promise<void> {
  await mkdir(RELEASES, { recursive: true });
  await mkdir(CHANNELS, { recursive: true });
}

export async function listReleaseTags(): Promise<string[]> {
  try {
    const entries = await readdir(RELEASES, { withFileTypes: true });
    return entries.filter((e) => e.isDirectory() && validTag(e.name)).map((e) => e.name);
  } catch {
    return [];
  }
}

export async function readManifest(tag: string): Promise<Manifest | null> {
  try {
    return JSON.parse(await readFile(releasePath(tag, "manifest.json"), "utf8")) as Manifest;
  } catch {
    return null;
  }
}

export async function writeManifest(tag: string, m: Manifest): Promise<void> {
  await writeFile(releasePath(tag, "manifest.json"), JSON.stringify(m, null, 2));
}

/**
 * Only releases with a manifest are visible. A half-finished upload has no
 * manifest, so it cannot be listed, served through the API, or promoted —
 * an interrupted publish is invisible rather than partially live.
 */
export async function listPublishedReleases(): Promise<Manifest[]> {
  const tags = await listReleaseTags();
  const manifests = await Promise.all(tags.map((t) => readManifest(t)));
  return manifests
    .filter((m): m is Manifest => m !== null)
    .sort((a, b) => b.published_at.localeCompare(a.published_at));
}

export async function readChannel(channel: string): Promise<string | null> {
  try {
    const tag = (await readFile(channelPath(channel), "utf8")).trim();
    return validTag(tag) ? tag : null;
  } catch {
    return null;
  }
}

/**
 * Written via a temp file + rename so the channel pointer is never observed
 * half-written. This is the atomic act of releasing: everything before it is
 * staging, and a crash at any earlier point leaves the previous release live.
 */
export async function writeChannel(channel: string, tag: string): Promise<void> {
  const target = channelPath(channel);
  const tmp = `${target}.tmp`;
  await writeFile(tmp, `${tag}\n`);
  await rename(tmp, target);
}

export async function fileExists(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

export async function removeRelease(tag: string): Promise<void> {
  await rm(releasePath(tag), { recursive: true, force: true });
}

/** Streamed so a 130 MB tarball never lands in memory all at once. */
export async function sha256File(path: string): Promise<string> {
  const hasher = new Bun.CryptoHasher("sha256");
  const stream = Bun.file(path).stream();
  for await (const chunk of stream) hasher.update(chunk);
  return hasher.digest("hex");
}
