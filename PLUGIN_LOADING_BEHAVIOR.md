# v2 migration

The authoritative contract is [`docs/specs/v2.md`](docs/specs/v2.md).

## Removed

- Shells other than Zsh.
- Built-in aliases for `gh_source`.
- Positional setup commands, `{}` replacement, and current-shell `eval`.
- `GH_SOURCE_INSTALL_LOCATION`; use `GH_SOURCE_ROOT`.
- `PLUGINS`; use `--loaded` or `--list`.
- `--require`; use `--loaded`.
- `--at` and explicit checkout overrides.
- `--worktree` and `GH_SOURCE_WORKTREE`.
- `--layout`, `--shared-dir`, and worktree creation.
- `GH_SOURCE_NEW_REPO_LAYOUT` and `GH_SOURCE_WORKTREE_SHARED_DIR`.
- Automatic discovery below the checkout root.
- Physical-path and symlink-alias idempotency semantics.
- `--reload`; start a new shell when a fresh activation is needed.

## Renamed

```text
--append-path  -> --path
--prepend-fpath -> --fpath
```

The unused `--prepend-path` and `--append-fpath` variants were removed.

## Source Migration

```zsh
# Equivalent forms
gh_source owner/repo/plugin.zsh
gh_source owner/repo --source plugin.zsh
```

Replace evaluated setup with actions:

```zsh
# v1
gh_source owner/repo 'export PATH="$PATH:{}/bin"; source {}/plugin.zsh'

# v2
gh_source owner/repo/plugin.zsh --path bin
```

Nested files are explicit:

```zsh
gh_source owner/repo/scripts/repo.zsh
```

## Build Migration

```zsh
gh_source owner/tool/scripts/tool.zsh \
  --skip-build-if-present tool \
  --skip-build-if-present target/release/tool \
  --build cargo build --release
```

Build argv runs from the checkout and is never implicitly evaluated.

## Worktree Migration

New repositories clone normally. Convert them separately when needed:

```zsh
"$DOTFILES/bin/wt-migrate" --yes "$HOME/Github/<repo>"
```

Existing `.bare/` containers and primary worktrees continue to resolve automatically.
