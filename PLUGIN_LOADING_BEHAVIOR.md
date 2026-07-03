# Plugin Loading Behavior

`gh-source` is a small shell plugin loader for GitHub-hosted shell plugins. It exposes `gh_source` and convenience aliases that clone a GitHub repository on first use, then load or run code from the local checkout.

This specification describes the plugin loading behavior implemented by `gh-source.zsh`.

## Goals

- Let shell configuration install and load GitHub-hosted plugins from one line.
- Use the GitHub CLI for first-time repository cloning.
- Keep plugin state in the current shell session so plugins can be listed, required, and updated.
- Avoid a separate plugin manifest or lock file.
- Keep cached plugin loading fast enough for interactive shell startup.

## Public Interface

### Functions

The project defines these shell functions:

- `gh_source`: canonical function.
- `gh-source`: wrapper around `gh_source "$@"`.
- `ghsource`: wrapper around `gh_source $@`.
- `ghs`: wrapper around `gh_source $@`.

`gh-source` preserves argument boundaries. `ghsource` and `ghs` pass unquoted arguments and therefore allow normal shell word splitting.

### Usage Shape

```sh
gh_source [option]
gh_source <plugin>
gh_source <plugin> <install_command>
gh_source <plugin> <install_command> <install_location>
```

Examples:

```sh
gh_source owner/repo/script.zsh
gh_source owner/repo 'source {}/script.zsh && echo loaded'
gh_source owner/repo 'source {}/script.zsh' /home/user/special_location
gh_source --update
```

## Dependencies

- `gh` is required only when a requested repository is missing and must be cloned.
- First-time clones require `gh auth status` to succeed.
- `git` is required for `--update`.
- Zsh completion support requires Zsh.

Already-cloned plugin loads do not require `gh` to be available. This keeps interactive shell startup resilient when GitHub CLI is missing or temporarily broken.

## State And Environment

### `GH_SOURCE_PLUGINS`

In Zsh, `GH_SOURCE_PLUGINS` is an array used as the internal in-session registry of requested plugins.

- On a normal plugin load, the raw first argument is appended as one registry entry.
- Custom install commands and custom install locations are not stored in this registry.
- `--list`, `--require`, and `--update` read from this registry.

### `PLUGINS`

`PLUGINS` remains as an exported, space-delimited compatibility mirror.

- If unset, the first normal plugin load sets it to the plugin argument.
- Later normal plugin loads append ` <plugin>`.
- It is kept for compatibility, not preferred for new internal behavior.

### `GH_SOURCE_INSTALL_LOCATION`

`GH_SOURCE_INSTALL_LOCATION` controls the default parent directory for cloned repositories.

- If set, default installs are placed under that directory.
- If unset, default installs are placed under `$HOME/Github`.

For a plugin whose install source is `owner/repo`, the default install location is:

```sh
$GH_SOURCE_INSTALL_LOCATION/repo
```

or, when `GH_SOURCE_INSTALL_LOCATION` is unset:

```sh
$HOME/Github/repo
```

## Plugin Argument Semantics

The plugin argument is interpreted as a GitHub repository plus an optional path inside that repository:

```text
owner/repo/path/inside/repo.zsh
```

For this value:

- Install source: `owner/repo`.
- Repository name: `repo`.
- Plugin path: `path/inside/repo.zsh`.
- Default install location: `$GH_SOURCE_INSTALL_LOCATION/repo` or `$HOME/Github/repo`.

If the plugin argument is only `owner/repo`, there is no default plugin path. In that case, callers must provide a custom install command.

The plugin argument must contain at least `owner/repo`. Invalid plugin arguments fail with an error.

## Normal Cached Plugin Load

Given an already-cloned repository:

```sh
gh_source owner/repo/plugin.zsh
```

`gh_source` must:

1. Parse the plugin argument with shell parameter expansion.
2. Register the exact plugin argument in the in-session registry.
3. Resolve the install location.
4. Confirm the install location exists.
5. Clear positional parameters with `set --`.
6. Source the plugin file directly with `source "$install_location/$plugin_path"`.

Cached plugin loads are optimized for interactive shell startup:

- No `gh` lookup.
- No clone/auth checks.
- No external parsing commands such as `cut` or `basename`.
- No `eval` for the default source path.

If the install location exists but the source file is missing, the shell's normal `source` failure behavior applies.

## First-Time Clone Behavior

When the install location does not exist, `gh_source` must:

1. Verify `gh` is available.
2. Run `gh auth status` and fail if authentication is missing.
3. Print `Cloning <owner/repo> to <install_location>`.
4. Run `gh repo clone <owner/repo> <install_location>`.
5. Verify the install location exists after cloning.
6. Continue to the normal load path.

If `gh` is unavailable, authentication fails, cloning fails, or the expected directory is still missing after clone, `gh_source` returns non-zero and does not evaluate custom commands or source plugin files.

## Default Source Command Behavior

When no custom install command is provided, `gh_source` loads the plugin file directly:

```sh
source "$install_location/$plugin_path"
```

If no plugin path is present, `gh_source` fails with:

```text
No plugin path provided for <plugin> and no install command was passed
```

## Custom Install Commands

A caller may provide an install command as the second argument:

```sh
gh_source owner/repo 'source {}/script.zsh && echo loaded'
```

Behavior:

- The install source remains the first two path segments of the plugin argument.
- `{}` in the custom command is replaced with the resolved install location.
- The command is evaluated with `eval` in the current shell.
- Positional parameters are cleared before evaluation.

Custom commands are useful when the repository path alone is not enough, for example when multiple commands must run or the source file path is not encoded in the plugin argument.

## Custom Install Locations

A caller may provide an install location as the third argument:

```sh
gh_source owner/repo 'source {}/script.zsh' /home/user/special_location
```

Behavior:

- The repository is cloned to the provided path if that path does not exist.
- `{}` in the install command resolves to the provided path.
- The custom location is used only for that immediate load operation.
- The custom location is not stored in the registry, so later `--update` calls use the default location derived from the plugin string.

## Options

Options are recognized only as the first argument.

### No Argument Or `--help`

```sh
gh_source
gh_source --help
```

Prints usage, examples, options, and argument descriptions to stdout, then returns.

### `--list`

```sh
gh_source --list
```

Prints the current plugin registry as newline-separated entries. It does not print a leading blank line.

### `--require`

```sh
gh_source --require <plugin-or-repo>
```

Checks whether a plugin has been registered.

Behavior:

- Exact full plugin specs match, for example `owner/repo/plugin.zsh`.
- Exact repository specs match, for example `owner/repo`.
- Substrings do not match.
- If no match is found, writes `Required plugin : <plugin-or-repo> not found` to stderr and returns exit code `1`.

This allows repo-level checks such as:

```sh
gh_source zsh-users/zsh-history-substring-search/zsh-history-substring-search.zsh
gh_source --require zsh-users/zsh-history-substring-search
```

while avoiding false positives such as `owner/repo` matching `owner/repo-extra/plugin.zsh`.

### `--update`

```sh
gh_source --update
```

Updates plugins listed in the registry.

Behavior:

1. Requires `git` to be available.
2. Resolves the default install parent from `GH_SOURCE_INSTALL_LOCATION` or `$HOME/Github`.
3. Iterates each registered plugin.
4. Prints `Updating <plugin>` for each entry.
5. Resolves the install source and install location from the plugin argument.
6. If the install location exists, runs:

```sh
git --git-dir "$install_location"/.git --work-tree "$install_location" pull
git --git-dir "$install_location"/.git --work-tree "$install_location" reset --hard --quiet
```

7. Skips missing install locations.
8. Prints `Done updating` when iteration completes.

Current update behavior is intentionally tied to the registry and default install locations. It does not use custom install locations passed during the original plugin load.

## Zsh Completion Behavior

When sourced from a Zsh session, `gh-source.zsh` appends this project completion directory to `FPATH`:

```sh
<gh-source repo>/zsh-completion
```

The path is resolved using Zsh-native script path expansion so the normal source path does not spawn `dirname`.

The completion file defines completions for `gh_source`.

Completion behavior:

- Position 1 completes a plugin argument and falls back to file completion.
- Position 2 describes `install_command`.
- Position 3 completes directories for `install_location`.
- Options include `--help`, `--update`, `--list`, and `--require`.

The completion file is scoped to `gh_source`; aliases may require separate completion binding if alias completion is desired.

## Release Workflow

The GitHub Actions workflow in `.github/workflows/ci.yml` runs on pushes to `main`, except for documentation and metadata-only paths ignored by the workflow.

The workflow:

1. Checks out the repository on `macos-latest`.
2. Creates and pushes a version tag with `mathieudutour/github-tag-action@v6.1`.
3. Creates a GitHub release with `ncipollo/release-action@v1`.
4. Opens or updates a Homebrew formula pull request with `brew bump-formula-pr`.

The workflow expects `secrets.TOKEN` to have permission to tag, release, and interact with the Homebrew tap.

## Compatibility Expectations

- The primary target shell is Zsh.
- The function uses some Zsh-specific behavior for arrays and completion setup.
- The default cached plugin source path is optimized for repeated interactive Zsh startup.
- `PLUGINS` remains available as a compatibility mirror but should not be preferred for new integrations.
- The `ghsource` and `ghs` wrappers pass unquoted arguments, unlike `gh-source`.

## Known Limitations

- Plugin names or paths containing spaces are not supported by the compatibility `PLUGINS` mirror.
- `--update` performs `git reset --hard --quiet` after pulling, which discards local changes in managed plugin repositories.
- Custom install commands and custom install locations are not recorded for later updates.
