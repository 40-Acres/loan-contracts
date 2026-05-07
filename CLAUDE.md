# loan-contracts

40Acres smart contracts (Foundry/Solidity) plus the published `@40-acres/contracts` npm package that bundles ABIs and addresses for downstream consumers (frontend, homestead).

## Architecture

- `src/` — Solidity contracts. Built with Foundry.
- `addresses/<network>/<platform>.json` — address registry. Source of truth for every deployed 40Acres contract per chain. Schema in [addresses/README.md](addresses/README.md).
- `packages/contracts/` — the publishable npm package. ABIs auto-generated from Foundry artifacts via `wagmi-cli`; addresses generated from the JSON registry.
- `wagmi.config.ts` — controls which ABIs the package exports.
- `script/` — Foundry deploy/upgrade scripts.
- `.changeset/` — pending-release entries. CI rolls these into version bumps + changelog.

## Release flow

Every change ships through **2 PRs**:

1. **Dev's PR** — code/address change + a `.changeset/<random>.md` file describing it.
2. **"Version Packages" PR** — auto-opened by CI after #1 merges. Bumps `packages/contracts/package.json`, fills `packages/contracts/CHANGELOG.md`, deletes the consumed changeset files. **A human merges this to publish.**

Merging the Version Packages PR triggers `release.yml`, which:
- Publishes `@40-acres/contracts` to GitHub Packages.
- Fires `repository_dispatch (contracts-released)` to consumer repos. Currently `frontend`; `homestead` joins in Phase 4.
- Consumer's listener auto-opens a bump PR within ~3 minutes. Dependabot weekly is the safety net.

## Changeset rules

**A `.changeset/*.md` file is what triggers a release.** No file → no version PR → no publish. The pre-commit hook only enforces it for `addresses/**/*.json`; Solidity and `wagmi.config.ts` changes can silently merge without one and never publish.

**Bump levels:**

| Change | Bump |
|---|---|
| New ABI exported, new address added (new key) | `minor` |
| Redeploy same contract (ABI unchanged, only address moved) | `patch` |
| Bug fix in Solidity that doesn't change ABI shape | `patch` |
| Removed ABI / removed address / renamed function / changed signature | `major` |

**File format** (`.changeset/<4-hex-chars>.md`):

```markdown
---
"@40-acres/contracts": <patch|minor|major>
---

<one-line summary describing what changed for downstream consumers>
```

**Summary writing.** Audience is anyone reading the changelog later. Mention: which contract, which platform, which chain, hex prefix of new addresses (for deploys).

- Bad: "Updates", "Fix bug", "Various changes"
- Good: "Aerodrome: redeploy `usdc-loan.factory` on base prod (`0xfeeb…` → `0x9673…`). ABI unchanged."

**Two helpers:**
- `pnpm changeset` — interactive prompts.
- `pnpm changeset:from-diff` — auto-drafts from address JSON diff. Always emits a `> _Add a one-line "why" above this footer_` placeholder that must be replaced with real prose before committing.

## Workflow examples

### A. Bug fix or refactor (no deploy)
```bash
# edit src/
forge build && forge test
pnpm changeset                    # → patch or minor
git add -A && git commit -m "fix(loan): ..."
git push && gh pr create
```

### B. Deploy (just new addresses)
```bash
forge script script/<X>.s.sol --chain-id <id> --rpc-url <url> --broadcast --verify
$EDITOR addresses/<network>/<platform>.json   # paste the deployed address from forge stdout
pnpm changeset:from-diff
git add addresses/ .changeset/
git commit -m "chore(addresses): ..."
git push && gh pr create
```

### C. Deploy a new contract version (A + B together)
One PR, one changeset describing both.

## Conventions

- Address validator (`addresses/validate.sh`) is POSIX-bash-3.2-compatible — no associative arrays, no `shopt -s globstar`. Use `find` + `case` if extending.
- Solidity rejects unicode em-dash; use `--` ASCII in comments and strings.
- NatSpec rejects bare `@40acres/contracts` in docstrings (interprets as a tag) — quote it.
- `git status --porcelain` parsing in scripts: use `.trimEnd()`, **not** `.trim()` — leading-space preservation matters for `slice(3)` to extract the path.

## Reference

- Package: https://github.com/orgs/40-Acres/packages/npm/contracts
- Address registry schema: [addresses/README.md](addresses/README.md)
- Release workflow: [.github/workflows/release.yml](.github/workflows/release.yml)
- Frontend auto-bump listener: `frontend/.github/workflows/contracts-released.yml`
- Pre-commit hook: [.githooks/pre-commit](.githooks/pre-commit)

---

## Guidelines for Claude

When the user has staged or modified any of:
- `addresses/**/*.json`
- `src/**/*.sol` (when ABI surface is affected — public/external function added, removed, renamed, or signature changed)
- `wagmi.config.ts`

…and no `.changeset/*.md` is staged, **proactively draft one before the commit**. Do not wait to be asked.

Drafting steps:
1. Read the diff carefully to determine the bump level using the table above.
2. For address changes: prefer running `pnpm changeset:from-diff`, then **edit out the placeholder line** and replace it with a real one-line summary.
3. For Solidity changes: write a fresh `.changeset/<4-hex-chars>.md` directly. Pick a random 4-character hex name (e.g. `auto-3f9a.md`).
4. The summary must follow the rules above (which contract, which chain, what changed). Don't write "Updates" or "Fix bug".
5. After writing the file, tell the user the bump level you chose, the summary you wrote, and ask them to confirm before committing.

Never `git commit --no-verify` to skip the pre-commit hook unless the user explicitly asks. The hook is the last line of defense against missing changesets on address changes.

When investigating a regression on a feature branch, **always verify whether the bug also reproduces on `main` before reading the branch diff.** A 30-second `git checkout main && reload` is faster than reading a large diff and guessing.
