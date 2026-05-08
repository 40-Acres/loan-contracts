#!/usr/bin/env bash
#
# Auto-draft a Changesets entry for the staged changes via Claude Code.
#
# What this does:
#   1. Verifies `claude` (Claude Code CLI) is on PATH.
#   2. Confirms there are staged changes worth a changeset.
#   3. Invokes `claude -p` with a prompt that points it at CLAUDE.md
#      for the bump rules + format and at `git diff --cached` for the
#      content. Claude writes a .changeset/auto-<hex>.md file and
#      stages it.
#
# Usage:  pnpm changeset:claude
#
# After it returns, review the generated file (it's not committed yet),
# edit if needed, and re-run `git commit`.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! command -v claude >/dev/null 2>&1; then
  cat >&2 <<'EOF'
❌ Claude Code CLI not found on PATH.

Install it from https://docs.claude.com/en/docs/claude-code/quickstart
or fall back to:
  pnpm changeset           (interactive)
  pnpm changeset:from-diff (auto from addresses JSON diff)
EOF
  exit 1
fi

if [[ -z "$(git diff --cached --name-only)" ]]; then
  echo "No staged changes -- stage the files you want covered by the changeset first." >&2
  exit 1
fi

# The prompt is intentionally short. CLAUDE.md at the repo root carries
# the actual rules (bump levels, file format, summary writing guidance,
# good/bad examples). Claude Code auto-loads CLAUDE.md when run from the
# repo, so we just have to point it at the staged diff.
prompt='Draft a Changesets entry for the currently staged changes in this repo.

Steps:
  1. Read CLAUDE.md for the bump-level table, file format, and summary-writing rules.
  2. Read the staged diff with: git diff --cached
  3. Decide the bump level (patch/minor/major). Be honest -- a renamed/removed/changed-signature anywhere in src/**/*.sol is MAJOR even if the rest of the diff is small.
  4. Write a new file at .changeset/auto-<4-random-hex-chars>.md with the proper frontmatter and a one-line summary that mentions which contract / platform / chain / hex prefix as appropriate. No placeholder prose ("Updates", "Fix bug", etc).
  5. Run: git add .changeset/auto-<that-hex>.md
  6. Print only the path you created -- nothing else.'

# --permission-mode bypassPermissions: needed because the prompt asks
# Claude to write a file and run `git add`. Without it, claude -p would
# halt asking for approval, which there's no way to grant in non-
# interactive mode. The scope is narrow: this single invocation, this
# specific prompt. The dev runs the script knowingly.
claude -p --permission-mode bypassPermissions "$prompt"
