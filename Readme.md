# gh-source v2

gh-source v2 is a small Zsh-only GitHub plugin loader focused on fast startup and readable declarations.

It clones missing repositories, detects existing regular or nested-worktree checkouts, performs declarative setup, and sources plugins in the active shell.

## Install

```zsh
brew install yarden-zamir/tap/gh-source
```

Use the fixed path printed by `brew info gh-source` rather than running `brew --prefix` during every shell startup:

```zsh
source /opt/homebrew/opt/gh-source/share/gh-source/gh-source.zsh
```

Only the `gh_source` function is provided.

## Source Plugins

```zsh
gh_source hlissner/zsh-autopair/autopair.zsh
```

The path shorthand equals an explicit source action:

```zsh
gh_source hlissner/zsh-autopair --source autopair.zsh
```

Additional sources run in declaration order:

```zsh
gh_source junegunn/fzf/shell/completion.zsh \
  --path bin \
  --preserve-zsh-options \
  --source shell/key-bindings.zsh
```

`--preserve-zsh-options` runs sources in Zsh's native `LOCAL_OPTIONS` scope. It prevents option changes from leaking on success or failure and hides `$options` for scripts such as fzf that try to restore the immutable `zle` option. Ordinary calls do not inspect or restore options.

With no explicit source, `gh_source owner/repo` checks the resolved checkout root for:

```text
<repo>.plugin.zsh
<repo>.zsh
init.zsh
```

Files under `scripts/` or other directories require an explicit path.

## PATH And Completions

```zsh
gh_source owner/tool --path bin
gh_source owner/completions --fpath zsh
```

`--path` appends to `PATH`. `--fpath` prepends to `fpath`. Both resolve relative to the selected checkout and avoid duplicate entries.

## Conditional Builds

```zsh
gh_source Yarden-zamir/navgator/scripts/navgator.zsh \
  --skip-build-if-present navgator \
  --skip-build-if-present target/release/navgator \
  --build cargo build --release
```

Each predicate first checks for a regular file under the checkout, then calls `command -v` with the same value. Any match skips the build.

`--build` must be final. Its argv runs directly in a subshell rooted at the checkout. Build commands receive:

```text
GH_SOURCE_DIR
GH_SOURCE_REPO
GH_SOURCE_REPO_NAME
```

A successful build must make at least one predicate true.

## Repository Layout

Repositories default to:

```text
$GH_SOURCE_ROOT/<repo>
```

`GH_SOURCE_ROOT` defaults to `$HOME/Github`.

Missing repositories always clone normally. Existing worktree containers resolve automatically through `.bare/HEAD`, with `main/` as fallback.

To convert a cloned repository to the nested layout, use dedicated worktree tooling:

```zsh
"$DOTFILES/bin/wt-migrate" --yes "$HOME/Github/<repo>"
```

The next `gh_source` call automatically uses the primary worktree. gh-source does not create `_shared/`, convert repositories, or select arbitrary worktrees.

## State And Updates

```zsh
gh_source --loaded owner/repo
gh_source --loaded owner/repo/file.zsh
gh_source --list
gh_source --update
```

Sources load once per shell. Only complete successful activations are registered.

Updates deduplicate resolved roots, refuse dirty repositories, and run `git pull --ff-only`. They never reset or discard changes.

## Source Semantics

Sources see caller Zsh options. Option changes persist unless `--preserve-zsh-options` is present.

Zsh treats plain `typeset` inside any function as local; plugins must use assignment or `typeset -g` for persistent globals.

Parameter names beginning with `_ghs_` are reserved for loader internals while sources run.

If sourcing fails, PATH, fpath, and effects from any started source cannot be rolled back.

## Development

```zsh
uv run tests/test_gh_source.py
uvx ruff check tests/test_gh_source.py
zsh -n gh-source.zsh
```

The complete v2 behavior contract is in [`docs/specs/v2.md`](docs/specs/v2.md). Migration notes are in [`PLUGIN_LOADING_BEHAVIOR.md`](PLUGIN_LOADING_BEHAVIOR.md).
