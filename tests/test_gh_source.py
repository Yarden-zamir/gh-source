#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

import os
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUT = ROOT / "gh-source.zsh"


class GhSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="gh-source-tests-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.repos = self.base / "repos"
        self.home.mkdir()
        self.repos.mkdir()
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), GH_SOURCE_ROOT=str(self.repos))

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], check=True, capture_output=True, text=True)

    def regular(self, identity: str = "acme/tool") -> Path:
        checkout = self.repos / identity.split("/", 1)[1]
        checkout.mkdir()
        self.git("init", "-q", "-b", "main", str(checkout))
        self.git("-C", str(checkout), "remote", "add", "origin", f"https://github.com/{identity}.git")
        return checkout.resolve()

    def worktree(self, identity: str = "acme/tool") -> Path:
        container = self.repos / identity.split("/", 1)[1]
        checkout = container / "main"
        metadata = container / ".bare" / "worktrees" / "main"
        checkout.mkdir(parents=True)
        metadata.mkdir(parents=True)
        self.git("init", "-q", "--bare", "--initial-branch=main", str(container / ".bare"))
        self.git("--git-dir", str(container / ".bare"), "remote", "add", "origin", f"https://github.com/{identity}.git")
        (checkout / ".git").write_text(f"gitdir: {metadata}\n")
        (metadata / "commondir").write_text("../..\n")
        return checkout.resolve()

    @staticmethod
    def write(path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def zsh(self, script: str) -> subprocess.CompletedProcess[str]:
        command = f"source {shlex.quote(str(SUT))}\n{textwrap.dedent(script)}"
        return subprocess.run(
            ["/bin/zsh", "-f", "-c", command],
            cwd=ROOT,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def install_clone_stub(self) -> None:
        seed = self.base / "seed"
        remote = self.base / "remote.git"
        self.git("init", "-q", "-b", "main", str(seed))
        self.write(seed / "plugin.zsh", "typeset -g TEST_CLONED=1\n")
        self.git("-C", str(seed), "add", "plugin.zsh")
        commit_env = self.env | {
            "GIT_AUTHOR_NAME": "gh-source tests",
            "GIT_AUTHOR_EMAIL": "tests@example.invalid",
            "GIT_COMMITTER_NAME": "gh-source tests",
            "GIT_COMMITTER_EMAIL": "tests@example.invalid",
        }
        subprocess.run(["git", "-C", str(seed), "commit", "-qm", "fixture"], check=True, env=commit_env)
        self.git("clone", "-q", "--bare", str(seed), str(remote))
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        self.write(gh, """#!/bin/sh
[ "$1 $2" = "repo clone" ] || exit 90
repo=$3; dest=$4
if [ "$5 $6" = "-- --bare" ]; then
  "$REAL_GIT" clone -q --bare "$TEST_REMOTE" "$dest" || exit
  "$REAL_GIT" --git-dir="$dest" config remote.origin.url "https://github.com/$repo.git"
else
  "$REAL_GIT" clone -q "$TEST_REMOTE" "$dest" || exit
  "$REAL_GIT" -C "$dest" remote set-url origin "https://github.com/$repo.git"
fi
""")
        gh.chmod(0o755)
        self.env.update(
            PATH=f"{bin_dir}{os.pathsep}{self.env['PATH']}",
            REAL_GIT=shutil.which("git", path=self.env["PATH"]) or "git",
            TEST_REMOTE=str(remote),
        )

    def assert_zsh(self, script: str) -> None:
        result = self.zsh(script)
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)

    def test_direct_source_loaded_state_and_idempotency(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "(( TEST_LOADS += 1 ))\n")
        self.assert_zsh("""
            typeset -gi TEST_LOADS=0
            gh_source acme/tool/plugin.zsh || exit
            gh_source acme/tool/plugin.zsh || exit
            (( TEST_LOADS == 1 )) || exit 2
            gh_source --loaded acme/tool/plugin.zsh || exit 3
            gh_source acme/tool/./plugin.zsh || exit 4
            gh_source --loaded acme/tool/./plugin.zsh || exit 5
            [[ $(gh_source --list) == acme/tool/plugin.zsh ]]
        """)

    def test_worktree_fallback(self) -> None:
        checkout = self.worktree()
        self.write(checkout / "plugin.zsh", "typeset -g TEST_WORKTREE=main\n")
        self.assert_zsh("gh_source acme/tool/plugin.zsh && [[ $TEST_WORKTREE == main ]]")

    def test_no_action_discovery(self) -> None:
        checkout = self.regular()
        self.write(checkout / "tool.plugin.zsh", "typeset -g TEST_DISCOVERY=1\n")
        self.assert_zsh("gh_source acme/tool && (( TEST_DISCOVERY == 1 ))")

    def test_preflight_prevents_partial_source(self) -> None:
        checkout = self.regular()
        self.write(checkout / "first.zsh", "typeset -g TEST_PARTIAL=1\n")
        self.assert_zsh("""
            ! gh_source acme/tool --source first.zsh --source missing.zsh 2>/dev/null || exit
            (( ! ${+TEST_PARTIAL} ))
        """)

    def test_conditional_build_uses_direct_argv(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "typeset -g TEST_BUILT=1\n")
        build = checkout / "build.zsh"
        self.write(build, """#!/bin/zsh
[[ $1 == "a b" ]] || exit 9
[[ $PWD == "$GH_SOURCE_DIR" ]] || exit 10
[[ $GH_SOURCE_REPO == acme/tool && $GH_SOURCE_REPO_NAME == tool ]] || exit 11
touch artifact
""")
        build.chmod(0o755)
        self.assert_zsh("""
            gh_source acme/tool --source plugin.zsh \
              --skip-build-if-present artifact --build ./build.zsh 'a b' || exit
            [[ -f $GH_SOURCE_ROOT/tool/artifact && $TEST_BUILT == 1 ]] || exit 2
            ! gh_source acme/tool --source plugin.zsh --build true 2>/dev/null
        """)

    def test_build_failures_do_not_activate(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "typeset -g TEST_BUILD_FAILURE_SOURCE=1\n")
        self.assert_zsh("""
            ! gh_source acme/tool/plugin.zsh \
              --skip-build-if-present artifact --build zsh -c 'exit 6' 2>/dev/null || exit
            (( ! ${+TEST_BUILD_FAILURE_SOURCE} )) || exit 2
            ! gh_source --loaded acme/tool || exit 3
            ! gh_source acme/tool/plugin.zsh \
              --skip-build-if-present artifact --build true 2>/dev/null
        """)

    def test_preserves_zsh_options(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "typeset -g TEST_OPTIONS=${#options}; setopt extendedglob\n")
        self.assert_zsh("""
            unsetopt extendedglob
            gh_source acme/tool/plugin.zsh --preserve-zsh-options || exit
            (( TEST_OPTIONS == 0 )) && [[ ! -o extendedglob ]]
        """)

    def test_preservation_restores_enabled_caller_option(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "unsetopt extendedglob\n")
        self.assert_zsh("""
            setopt extendedglob
            gh_source acme/tool/plugin.zsh --preserve-zsh-options || exit
            [[ -o extendedglob ]]
        """)

    def test_preservation_restores_options_after_source_failure(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "setopt extendedglob\nreturn 7\n")
        self.assert_zsh("""
            unsetopt extendedglob
            if gh_source acme/tool/plugin.zsh --preserve-zsh-options; then exit 1; fi
            [[ ! -o extendedglob ]]
        """)

    def test_preserved_sources_share_one_local_option_scope(self) -> None:
        checkout = self.regular()
        self.write(checkout / "first.zsh", "setopt extendedglob\n")
        self.write(checkout / "second.zsh", "[[ -o extendedglob ]] || return 8\n")
        self.assert_zsh("""
            unsetopt extendedglob
            gh_source acme/tool --preserve-zsh-options \
              --source first.zsh --source second.zsh || exit
            [[ ! -o extendedglob ]]
        """)

    def test_preservation_survives_source_emulation(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "emulate zsh\n")
        self.assert_zsh("""
            setopt aliases
            gh_source acme/tool/plugin.zsh --preserve-zsh-options || exit
            [[ -o aliases ]]
        """)

    def test_path_action_and_failed_source_state(self) -> None:
        checkout = self.regular()
        (checkout / "bin").mkdir()
        self.write(checkout / "fail.zsh", "return 7\n")
        expected = shlex.quote(str(checkout / "bin"))
        self.assert_zsh(f"""
            gh_source acme/tool --path bin || exit
            [[ $path[-1] == {expected} ]] || exit 2
            ! gh_source acme/tool/fail.zsh 2>/dev/null || exit 3
            ! gh_source --loaded acme/tool/fail.zsh
        """)

    def test_rejects_wrong_origin(self) -> None:
        checkout = self.regular("other/tool")
        self.write(checkout / "plugin.zsh", ":\n")
        self.assert_zsh("! gh_source acme/tool/plugin.zsh 2>/dev/null")

    def test_refuses_dirty_update(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", ":\n")
        self.write(checkout / "untracked", "dirty\n")
        self.assert_zsh("gh_source acme/tool/plugin.zsh && ! gh_source --update 2>/dev/null")

    def test_update_deduplicates_roots_and_uses_ff_only(self) -> None:
        checkout = self.regular()
        self.write(checkout / "first.zsh", ":\n")
        self.write(checkout / "second.zsh", ":\n")
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        log = self.base / "git.log"
        fake_git = bin_dir / "git"
        self.write(fake_git, """#!/bin/sh
printf '%s\\n' "$*" >> "$GH_SOURCE_TEST_GIT_LOG"
exit 0
""")
        fake_git.chmod(0o755)
        self.env["PATH"] = f"{bin_dir}{os.pathsep}{self.env['PATH']}"
        self.env["GH_SOURCE_TEST_GIT_LOG"] = str(log)
        result = self.zsh("""
            gh_source acme/tool/first.zsh || exit
            gh_source acme/tool/second.zsh || exit
            gh_source --update
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = log.read_text().splitlines()
        pulls = [command for command in commands if " pull --ff-only" in command]
        self.assertEqual(pulls, [f"-C {checkout} pull --ff-only"])

    def test_defines_only_gh_source(self) -> None:
        self.assert_zsh("""
            [[ $(whence -w gh_source) == 'gh_source: function' ]] || exit
            [[ $(whence -w gh-source ghsource ghs) == *none* ]]
        """)

    def test_restores_directory_after_source_failure(self) -> None:
        checkout = self.regular()
        self.write(checkout / "fail.zsh", "setopt errreturn\ncd /\nreturn 7\n")
        expected = shlex.quote(str(ROOT))
        self.assert_zsh(f"""
            setopt errreturn
            if gh_source acme/tool/fail.zsh; then exit 1; else source_status=$?; fi
            (( source_status == 7 )) && [[ $PWD == {expected} ]]
        """)

    def test_supports_ksh_array_callers(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "[[ -o ksharrays && -o extendedglob ]] || return 8\ntypeset -g TEST_KSH_ARRAYS=1\n")
        self.assert_zsh("""
            setopt ksharrays extendedglob
            gh_source acme/tool/plugin.zsh || exit
            gh_source acme/tool/plugin.zsh || exit
            (( TEST_KSH_ARRAYS == 1 ))
        """)

    def test_supports_ksh_arrays_with_no_unset(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "typeset -g TEST_STRICT_OPTIONS=1\n")
        self.assert_zsh("""
            setopt ksharrays nounset
            gh_source acme/tool/plugin.zsh || exit
            (( TEST_STRICT_OPTIONS == 1 ))
        """)

    def test_sources_with_caller_options_and_keeps_changes(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "[[ -o extendedglob ]] || return 8\nunsetopt extendedglob\n")
        self.assert_zsh("setopt extendedglob; gh_source acme/tool/plugin.zsh && [[ ! -o extendedglob ]]")

    def test_deduplicates_equivalent_sources(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "(( TEST_DUPLICATES += 1 ))\n")
        self.assert_zsh("""
            typeset -gi TEST_DUPLICATES=0
            gh_source acme/tool --source plugin.zsh --source ./plugin.zsh || exit
            (( TEST_DUPLICATES == 1 )) || exit 2
            [[ $(gh_source --list) == acme/tool/plugin.zsh ]]
        """)

    def test_discovery_prefers_conventional_path_before_root(self) -> None:
        regular = self.regular()
        nested = regular / "main"
        nested.mkdir()
        self.git("init", "-q", "-b", "main", str(nested))
        self.git("-C", str(nested), "remote", "add", "origin", "https://github.com/acme/tool.git")
        self.write(regular / "init.zsh", "typeset -g TEST_DISCOVERY_ROOT=regular\n")
        self.write(nested / "tool.plugin.zsh", "typeset -g TEST_DISCOVERY_ROOT=worktree\n")
        self.assert_zsh("gh_source acme/tool && [[ $TEST_DISCOVERY_ROOT == worktree ]]")

    def test_stale_bare_head_falls_back_to_main(self) -> None:
        checkout = self.worktree()
        container = checkout.parent
        (container / ".bare" / "HEAD").write_text("ref: refs/heads/stale\n")
        self.write(checkout / "plugin.zsh", "typeset -g TEST_MAIN_FALLBACK=1\n")
        self.assert_zsh("gh_source acme/tool/plugin.zsh && (( TEST_MAIN_FALLBACK == 1 ))")

    def test_sources_receive_no_positional_arguments(self) -> None:
        checkout = self.regular()
        self.write(checkout / "first.zsh", "(( $# == 0 )) || return 9\nset -- leaked\n")
        self.write(checkout / "second.zsh", "(( $# == 0 )) || return 10\n")
        self.assert_zsh("gh_source acme/tool --source first.zsh --source second.zsh")

    def test_option_restoration_cannot_be_intercepted(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "setopt extendedglob\nsetopt() { return 0; }\n")
        self.assert_zsh("""
            unsetopt extendedglob
            gh_source acme/tool/plugin.zsh --preserve-zsh-options || exit
            [[ ! -o extendedglob ]]
        """)

    def test_checkout_root_path_action(self) -> None:
        checkout = self.regular()
        expected = shlex.quote(str(checkout))
        self.assert_zsh(f"gh_source acme/tool --path . && [[ $path[-1] == {expected} ]]")

    def test_symlink_specs_are_independent_logical_loads(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "(( TEST_SYMLINK += 1 ))\n")
        (checkout / "alias.zsh").symlink_to("plugin.zsh")
        self.assert_zsh("""
            typeset -gi TEST_SYMLINK=0
            gh_source acme/tool/plugin.zsh || exit
            gh_source acme/tool/alias.zsh || exit
            (( TEST_SYMLINK == 2 )) || exit 2
            gh_source --loaded acme/tool/plugin.zsh || exit 3
            gh_source --loaded acme/tool/alias.zsh
        """)

    def test_clones_regular_layout(self) -> None:
        self.install_clone_stub()
        self.assert_zsh("""
            gh_source acme/tool/plugin.zsh || exit
            [[ -d $GH_SOURCE_ROOT/tool/.git && $TEST_CLONED == 1 ]]
        """)

    def test_fpath_prepends_and_path_appends(self) -> None:
        checkout = self.regular()
        (checkout / "bin").mkdir()
        (checkout / "functions").mkdir()
        expected_path = shlex.quote(str(checkout / "bin"))
        expected_fpath = shlex.quote(str(checkout / "functions"))
        self.assert_zsh(f"""
            path=({expected_path} {expected_path} $path)
            gh_source acme/tool --path bin --fpath functions || exit
            matches=("${{(@M)path:#{expected_path}}}")
            (( ${{#matches}} == 1 )) && [[ $fpath[1] == {expected_fpath} ]]
        """)

    def test_source_only_activation_does_not_rewrite_path(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", ":\n")
        self.assert_zsh("""
            path=(/tmp/duplicate /tmp/duplicate $path)
            gh_source acme/tool/plugin.zsh || exit
            [[ $path[1] == /tmp/duplicate && $path[2] == /tmp/duplicate ]]
        """)

    def test_path_and_fpath_actions_do_not_rewrite_each_other(self) -> None:
        checkout = self.regular()
        (checkout / "bin").mkdir()
        (checkout / "functions").mkdir()
        self.assert_zsh("""
            fpath=(/tmp/functions /tmp/functions $fpath)
            gh_source acme/tool --path bin || exit
            [[ $fpath[1] == /tmp/functions && $fpath[2] == /tmp/functions ]] || exit 2
        """)

    def test_plugin_assignments_cannot_corrupt_registration(self) -> None:
        checkout = self.regular()
        self.write(checkout / "plugin.zsh", "pending=clobbered\nroot=/\nrestore=broken\ntypeset -g TEST_RESERVED_LOCALS=1\n")
        self.assert_zsh("""
            gh_source acme/tool/plugin.zsh || exit
            (( TEST_RESERVED_LOCALS == 1 )) || exit 2
            gh_source --loaded acme/tool/plugin.zsh || exit 3
            ! gh_source --loaded acme/tool/clobbered
        """)


if __name__ == "__main__":
    unittest.main()
