# gh-source Optimization Specification

## Purpose

Optimize `gh_source` for interactive shell startup while preserving its current public interface and first-run clone behavior.

The main target is the common startup path where all requested repositories already exist locally and `gh_source` only needs to resolve paths, register plugins, and source local files.

## Background

`gh_source` is used from `.zshrc` as a lightweight plugin loader. In this use case it runs many times during every interactive shell startup. Small per-call costs compound quickly.

Measured in a real dotfiles startup, `gh_source` calls contributed hundreds of milliseconds across multiple plugins. Directly sourcing equivalent Homebrew-installed plugin files was significantly faster than loading the same plugins through `gh_source`.

Example measurements from a clean interactive zsh process:

| Plugin | Direct source | `gh_source` path |
| --- | ---: | ---: |
| `zsh-autopair` | ~57 ms | ~145 ms including `gh-source.zsh` load |
| `zsh-syntax-highlighting` | ~31 ms | ~90 ms including `gh-source.zsh` load |

In real startup, `gh-source.zsh` is loaded once, so the per-plugin overhead is lower than the second column implies, but still measurable.

## Goals

- Make the already-cloned plugin path fast.
- Avoid external process spawning in the normal plugin load path.
- Keep first-run install behavior based on GitHub CLI.
- Preserve existing function names and argument shapes.
- Preserve support for custom install commands using `{}`.
- Keep the implementation simple shell code, without adding dependencies.
- Add an easy benchmark path so future changes can be measured.

## Non-Goals

- Do not replace `gh` as the clone/discovery tool.
- Do not introduce a lock file or manifest.
- Do not implement a full plugin manager.
- Do not auto-migrate existing clone locations.
- Do not remove custom install commands.
- Do not change update semantics unless explicitly called out below.

## Current Hot Path Costs

For each normal plugin load, the current implementation does work that is unnecessary when the repository already exists locally:

| Current operation | Cost / issue |
| --- | --- |
| `type -p gh` on every call | Repeated command lookup even when no clone is needed. |
| `export PLUGINS="$PLUGINS $1"` | Rebuilds and exports a growing string every call. |
| `echo "$1" \| cut -d'/' -f1,2` | Spawns external processes to parse `owner/repo`. |
| `echo "$1" \| cut -d'/' -f3-` | Spawns external processes to parse the path inside the repo. |
| `basename "$install_source"` | Spawns an external process to get the repo name. |
| `eval "$install_command"` | Needed for custom commands, but avoidable for the default `source` command. |
| `gh auth status` | Should remain first-clone only; never run on already-cloned plugins. |

## Required Behavior Compatibility

These examples must continue to work:

```sh
gh_source owner/repo/plugin.zsh
gh_source owner/repo 'source {}/plugin.zsh && echo loaded'
gh_source owner/repo 'source {}/plugin.zsh' /custom/path
gh_source --help
gh_source --list
gh_source --require owner/repo/plugin.zsh
gh_source --update
```

Aliases must continue to exist:

```sh
gh-source
ghsource
ghs
```

## Proposed Design

### 1. Defer `gh` Checks Until Clone Or Update

The normal already-cloned source path should not require checking for `gh`.

Required behavior:

- If a plugin directory already exists, `gh_source` may load it even when `gh` is unavailable.
- If a plugin directory is missing, `gh_source` must require `gh`, check authentication, and clone as today.
- `gh_source --update` must require `git`; it may require `gh` only if update behavior actually needs it.

This changes the current behavior where `gh` absence blocks even already-cloned plugin loading. This is an intentional startup resilience improvement.

### 2. Use Shell Parameter Expansion For Parsing

Replace external `echo`, `cut`, and `basename` calls with shell parameter expansion.

Given:

```sh
plugin=owner/repo/path/to/plugin.zsh
```

Expected resolved values:

```sh
install_source=owner/repo
repo_name=repo
plugin_path=path/to/plugin.zsh
install_location=$GH_SOURCE_INSTALL_LOCATION/repo
default_install_command='source {}/path/to/plugin.zsh'
```

Implementation should handle at least:

| Input | Install source | Repo name | Plugin path |
| --- | --- | --- | --- |
| `owner/repo/plugin.zsh` | `owner/repo` | `repo` | `plugin.zsh` |
| `owner/repo/path/plugin.zsh` | `owner/repo` | `repo` | `path/plugin.zsh` |
| `owner/repo` | `owner/repo` | `repo` | empty |

If no plugin path is present and no custom command is provided, fail with a clear error instead of evaluating `source {}/`.

### 3. Avoid `eval` For The Default Source Path

When no custom install command is provided, load the plugin directly:

```sh
source "$install_location/$plugin_path"
```

This avoids constructing and evaluating a command string for the most common use case.

Custom commands must continue to use placeholder replacement and `eval` because they may contain compound shell code:

```sh
gh_source owner/repo 'repo="{}"; source "$repo/file.zsh"; setup_plugin'
```

Required behavior:

- Default path: no `eval`.
- Custom command path: keep `eval`.
- Placeholder replacement must still replace every `{}` occurrence.

### 4. Improve Plugin Registry Internals

The current exported space-delimited `PLUGINS` string causes repeated string rebuilding and imprecise `--require` substring matching.

Preferred zsh implementation:

```sh
typeset -ga GH_SOURCE_PLUGINS
GH_SOURCE_PLUGINS+=("$plugin")
```

Compatibility requirements:

- `gh_source --list` must print one plugin per line.
- `gh_source --require <plugin>` must use exact matching, not substring matching.
- Existing users reading `$PLUGINS` are not a documented primary interface, but compatibility should be considered.

Recommended migration path:

- Maintain `PLUGINS` as a compatibility mirror for now.
- Use `GH_SOURCE_PLUGINS` internally when running under zsh.
- If shell arrays are unavailable, keep a simple newline-delimited internal string instead of a space-delimited string.

### 5. Cache Static Values Once

At file source time, initialize static values once:

```sh
GH_SOURCE_INSTALL_ROOT=${GH_SOURCE_INSTALL_LOCATION:-$HOME/Github}
```

Do not cache values that users reasonably expect to change during a shell session unless the behavior is documented.

Rules:

- `GH_SOURCE_INSTALL_LOCATION` may be read per call for compatibility.
- The path to `gh`, if needed, may be cached after first successful lookup.
- The completion directory should be resolved without external `dirname` in zsh where possible.

### 6. Keep Clone Path Correct And Explicit

When a repository is missing:

1. Verify `gh` is available.
2. Verify `gh auth status` succeeds.
3. Clone `owner/repo` into the resolved install location.
4. Verify the install location now exists.
5. Continue with plugin loading.

If cloning fails, return non-zero and do not evaluate install commands.

### 7. Keep Update Behavior Safe

`--update` currently runs `git pull` followed by `git reset --hard --quiet` for every known plugin path.

Optimization work should not make update behavior more destructive.

Minimum requirement:

- Preserve current behavior unless a separate update-safety change is explicitly made.

Recommended follow-up, outside this optimization if it grows too large:

- Add a `--update --hard` or config flag before using `reset --hard`.
- Track custom install locations so update can handle them accurately.

## Performance Acceptance Criteria

On an already-cloned plugin, the optimized normal path should:

- Spawn zero external processes before `source`.
- Avoid `gh` lookup.
- Avoid `cut`, `basename`, `grep`, `tr`, `awk`, and `dirname` on the hot path.
- Avoid `eval` for default source commands.

Target benchmark:

```sh
hyperfine --warmup 5 --runs 30 \
  'zsh -f -i -c "source ./gh-source.zsh; gh_source owner/repo/plugin.zsh"' \
  'zsh -f -i -c "source /path/to/repo/plugin.zsh"'
```

Expected outcome:

- The optimized `gh_source` path should be within ~10-20 ms of direct `source` for already-cloned plugins.
- The fixed per-call overhead should be small enough that 10 cached plugins add less than ~100 ms total over direct source, excluding plugin code itself.

## Functional Acceptance Criteria

Add tests or documented manual checks for:

- Loading an already-cloned plugin with default command.
- Loading a missing plugin clones it once and then sources it.
- Loading with custom command and `{}` replacement.
- Loading with custom install location.
- `--list` prints exact plugin entries, one per line, no leading blank line.
- `--require` succeeds only for exact registered plugins.
- `--require` fails for substrings.
- `--update` still updates registered plugins.
- Missing `gh` does not block already-cloned plugin loading.
- Missing `gh` does block first-time clone with a clear error.

## Suggested Implementation Steps

1. Add helper functions for parsing plugin specs using shell parameter expansion.
2. Add helper function for ensuring a repository exists locally.
3. Add a fast default-source path that bypasses command-string construction and `eval`.
4. Move `gh` availability checks into the clone path.
5. Add exact-match registry handling.
6. Update help text to describe the default source behavior without showing command-substitution internals.
7. Add benchmark notes or a small benchmark script.
8. Re-run startup benchmark against a real zshrc that uses many `gh_source` calls.

## Risks

- Shell portability: zsh arrays and parameter expansion are convenient but may reduce non-zsh compatibility if not guarded.
- `PLUGINS` compatibility: users may rely on the exported string even though it is mostly internal.
- Custom command behavior: placeholder replacement and current-shell execution are important; avoid changing quoting semantics unnecessarily.
- Default path behavior: failing on `owner/repo` without a plugin path may break accidental current behavior, but it is safer than evaluating `source repo/`.

## Open Questions

- Should zsh be the only supported shell, matching the practical usage, or should POSIX-ish compatibility remain a hard requirement?
- Should `PLUGINS` remain exported for compatibility, or should it become internal-only in a major version?
- Should custom install locations be tracked for `--update`?
- Should direct Homebrew-installed plugin paths be preferred by users when available, leaving `gh_source` primarily for GitHub-only plugins?
