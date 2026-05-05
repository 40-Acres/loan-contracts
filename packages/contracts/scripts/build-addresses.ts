#!/usr/bin/env tsx
/**
 * Reads every `addresses/{network}/{platform}.json` and emits a typed
 * `addresses` object as `packages/contracts/src/addresses.ts`.
 *
 * The output preserves the dev/prod env-awareness; consumers resolve at
 * runtime (matching the existing frontend pattern in src/config/protocols/env.ts).
 *
 * Run from the workspace root:  pnpm build:addresses
 */
import { readdirSync, readFileSync, writeFileSync, statSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const repoRoot = join(__dirname, '..', '..', '..');
const addressesDir = join(repoRoot, 'addresses');
const outFile = join(repoRoot, 'packages', 'contracts', 'src', 'addresses.ts');

type AddressFile = {
  chainId: number;
  network: string;
  platform: string;
  contracts: Record<string, unknown>;
};

function loadFiles(): AddressFile[] {
  const out: AddressFile[] = [];
  for (const network of readdirSync(addressesDir)) {
    const networkPath = join(addressesDir, network);
    let isDir = false;
    try {
      isDir = statSync(networkPath).isDirectory();
    } catch {
      continue;
    }
    if (!isDir) continue;

    for (const file of readdirSync(networkPath)) {
      if (!file.endsWith('.json')) continue;
      const content = readFileSync(join(networkPath, file), 'utf8');
      const parsed = JSON.parse(content) as AddressFile;
      out.push(parsed);
    }
  }
  return out;
}

function build() {
  const files = loadFiles();
  if (files.length === 0) {
    console.error('No address files found under', addressesDir);
    process.exit(1);
  }

  // Group by network → platform → contracts
  const tree: Record<string, Record<string, AddressFile['contracts']>> = {};
  for (const f of files) {
    if (!tree[f.network]) tree[f.network] = {};
    if (tree[f.network][f.platform]) {
      console.error(`Duplicate platform: ${f.network}/${f.platform}`);
      process.exit(1);
    }
    tree[f.network][f.platform] = f.contracts;
  }

  // Sort keys for deterministic output (avoids spurious diffs)
  const sortedTree: typeof tree = {};
  for (const network of Object.keys(tree).sort()) {
    sortedTree[network] = {};
    for (const platform of Object.keys(tree[network]).sort()) {
      sortedTree[network][platform] = tree[network][platform];
    }
  }

  const json = JSON.stringify(sortedTree, null, 2);
  const ts = `// AUTO-GENERATED — do not edit by hand.
// Source: addresses/**/*.json
// Regenerate with: pnpm build:addresses

export const addresses = ${json} as const;

export type Addresses = typeof addresses;

/**
 * An address that may differ per environment. Consumers resolve at runtime
 * based on their own NEXT_PUBLIC_IS_DEV / equivalent flag. This mirrors the
 * pattern at frontend/src/config/protocols/env.ts.
 */
export type EnvAware<T> = T | { dev: T; prod: T };
`;

  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, ts);

  const total = files.length;
  const networks = Object.keys(sortedTree).length;
  console.log(`Wrote ${outFile}`);
  console.log(`  ${total} platform file(s) across ${networks} network(s)`);
}

build();
