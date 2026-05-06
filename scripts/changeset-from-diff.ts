#!/usr/bin/env tsx
/**
 * Reads `git diff` of addresses/ and emits a draft changeset describing
 * what changed. The dev still adds a one-line "why"; the mechanical part
 * (which addresses moved, bump level) is auto-generated.
 *
 * Bump rules:
 *   - new file or new top-level key  → minor
 *   - removed file or removed key    → major
 *   - changed value (same key)       → patch
 *
 * Run from the workspace root:  pnpm changeset:from-diff
 */
import { execSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { basename } from 'node:path';

type Bump = 'patch' | 'minor' | 'major';

type Change =
  | { kind: 'newFile';     file: string; platform: string; network: string }
  | { kind: 'removedFile'; file: string; platform: string; network: string }
  | { kind: 'added';       file: string; platform: string; network: string; path: string }
  | { kind: 'removed';     file: string; platform: string; network: string; path: string }
  | { kind: 'modified';    file: string; platform: string; network: string; path: string; from: string; to: string };

function sh(cmd: string): string {
  // trimEnd only — preserves leading whitespace on the first line, which
  // matters for `git status --porcelain` where ' M file' would otherwise
  // become 'M file' and slice(3) would lose the first path character.
  return execSync(cmd, { encoding: 'utf8' }).trimEnd();
}

function shOk(cmd: string): string | null {
  try {
    return sh(cmd);
  } catch {
    return null;
  }
}

function listChangedAddressFiles(): { code: string; path: string }[] {
  // Includes staged, unstaged, and untracked.
  const out = sh('git status --porcelain -- addresses/');
  if (!out) return [];
  return out
    .split('\n')
    .map((line) => {
      const code = line.slice(0, 2).trim();
      const path = line.slice(3);
      return { code, path };
    })
    .filter(({ path }) => path.endsWith('.json') && path !== 'addresses/addresses.json');
}

function parsePlatformAndNetwork(file: string): { network: string; platform: string } {
  // addresses/{network}/{platform}.json
  const parts = file.split('/');
  return {
    network: parts[1] ?? 'unknown',
    platform: basename(parts[2] ?? '', '.json'),
  };
}

function deepDiff(
  oldObj: unknown,
  newObj: unknown,
  prefix: string,
  out: { added: string[]; removed: string[]; modified: { path: string; from: string; to: string }[] },
): void {
  if (typeof oldObj !== 'object' || oldObj === null || typeof newObj !== 'object' || newObj === null) {
    if (oldObj !== newObj) {
      out.modified.push({ path: prefix, from: String(oldObj), to: String(newObj) });
    }
    return;
  }

  const oldKeys = new Set(Object.keys(oldObj as Record<string, unknown>));
  const newKeys = new Set(Object.keys(newObj as Record<string, unknown>));

  for (const k of newKeys) {
    const path = prefix ? `${prefix}.${k}` : k;
    if (!oldKeys.has(k)) {
      out.added.push(path);
    } else {
      deepDiff(
        (oldObj as Record<string, unknown>)[k],
        (newObj as Record<string, unknown>)[k],
        path,
        out,
      );
    }
  }
  for (const k of oldKeys) {
    if (!newKeys.has(k)) {
      const path = prefix ? `${prefix}.${k}` : k;
      out.removed.push(path);
    }
  }
}

function collectChanges(): Change[] {
  const changes: Change[] = [];
  for (const { code, path } of listChangedAddressFiles()) {
    const { network, platform } = parsePlatformAndNetwork(path);

    // Untracked or git-added file → new file.
    if (code === '??' || code === 'A') {
      changes.push({ kind: 'newFile', file: path, platform, network });
      continue;
    }
    // Deleted.
    if (code === 'D') {
      changes.push({ kind: 'removedFile', file: path, platform, network });
      continue;
    }

    // Modified — diff old vs new.
    const oldText = shOk(`git show HEAD:${path}`);
    if (oldText === null) {
      // Couldn't read HEAD version; treat as new.
      changes.push({ kind: 'newFile', file: path, platform, network });
      continue;
    }
    let oldJson: unknown;
    let newJson: unknown;
    try {
      oldJson = JSON.parse(oldText);
      newJson = JSON.parse(readFileSync(path, 'utf8'));
    } catch (e) {
      console.error(`Skipping ${path}: invalid JSON (${(e as Error).message})`);
      continue;
    }

    const diff = { added: [] as string[], removed: [] as string[], modified: [] as { path: string; from: string; to: string }[] };
    deepDiff(oldJson, newJson, '', diff);

    for (const p of diff.added)    changes.push({ kind: 'added', file: path, platform, network, path: p });
    for (const p of diff.removed)  changes.push({ kind: 'removed', file: path, platform, network, path: p });
    for (const m of diff.modified) changes.push({ kind: 'modified', file: path, platform, network, path: m.path, from: m.from, to: m.to });
  }
  return changes;
}

function decideBump(changes: Change[]): Bump {
  const hasRemoved = changes.some((c) => c.kind === 'removed' || c.kind === 'removedFile');
  const hasAdded   = changes.some((c) => c.kind === 'added'   || c.kind === 'newFile');
  if (hasRemoved) return 'major';
  if (hasAdded)   return 'minor';
  return 'patch';
}

function shorten(addr: string): string {
  if (/^0x[0-9a-fA-F]{40}$/.test(addr)) {
    return `${addr.slice(0, 8)}…${addr.slice(-4)}`;
  }
  return addr;
}

function formatSummary(changes: Change[]): string {
  // Group by platform for readability.
  const byPlatform = new Map<string, Change[]>();
  for (const c of changes) {
    const key = `${c.network}/${c.platform}`;
    if (!byPlatform.has(key)) byPlatform.set(key, []);
    byPlatform.get(key)!.push(c);
  }

  const lines: string[] = [];
  for (const [platform, group] of byPlatform) {
    lines.push(`**${platform}**`);
    for (const c of group) {
      switch (c.kind) {
        case 'newFile':     lines.push(`  - new platform file`); break;
        case 'removedFile': lines.push(`  - **removed platform file**`); break;
        case 'added':       lines.push(`  - added \`${c.path}\``); break;
        case 'removed':     lines.push(`  - **removed** \`${c.path}\``); break;
        case 'modified':    lines.push(`  - changed \`${c.path}\`: ${shorten(c.from)} → ${shorten(c.to)}`); break;
      }
    }
    lines.push('');
  }
  return lines.join('\n').trimEnd();
}

function main() {
  const changes = collectChanges();
  if (changes.length === 0) {
    console.log('No address changes detected.');
    return;
  }

  const bump = decideBump(changes);
  const summary = formatSummary(changes);

  const id = randomBytes(4).toString('hex');
  const path = `.changeset/auto-${id}.md`;
  const body = `---
"@40-acres/contracts": ${bump}
---

${summary}

> _Add a one-line "why" above this footer before committing._
`;

  mkdirSync('.changeset', { recursive: true });
  writeFileSync(path, body);

  console.log(`Wrote ${path}`);
  console.log(`  ${changes.length} change(s) → ${bump} bump`);
  console.log('');
  console.log('Edit the file to add a one-line "why" before committing.');
}

main();
