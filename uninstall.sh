#!/usr/bin/env bash
# Undoes what install.sh did to a repository. Run it inside that repository:
#
#   bash /path/to/codemender-starter/uninstall.sh
#
# It stops the local dashboard, removes the commit hooks (and restores the hooks
# you had before), and removes the codemender.* settings and dashboard data of
# this repository.
# It leaves alone: the cm CLI, the records in ~/.codemender, and
# .github/workflows/codemender.yml.
set -uo pipefail

MARK="codemender-starter-hook"

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

repo_root="$(git rev-parse --show-toplevel 2> /dev/null)" || die "Run this script inside the repository that was set up."
cd "$repo_root" || die "Cannot enter the repository: $repo_root"
say "Repository: $repo_root"
git_dir="$(git rev-parse --absolute-git-dir)"

# Dashboard server.
pid_file="$git_dir/codemender/dashboard/server.pid"
if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2> /dev/null; then
  kill "$(cat "$pid_file")" 2> /dev/null || true
  say "Stopped the local dashboard."
fi

# Hooks.
hooks_dir="$(git rev-parse --git-path hooks)"
removed=0
for name in pre-commit post-commit; do
  hook_file="$hooks_dir/$name"
  if [ -f "$hook_file" ] && grep -q "$MARK" "$hook_file"; then
    rm -f "$hook_file"
    removed=1
    if [ -e "$hook_file.before-codemender" ]; then
      mv "$hook_file.before-codemender" "$hook_file"
      say "Removed the CodeMender $name hook and restored the one you had before."
    else
      say "Removed the CodeMender $name hook."
    fi
  fi
done
for name in codemender-pre-commit codemender-post-commit; do
  if [ -f "$git_dir/$name" ]; then
    rm -f "$git_dir/$name"
    removed=1
    say "Deleted $git_dir/$name. If you added a line that calls it to your own hook, please delete that line."
  fi
done
[ "$removed" -eq 1 ] || say "No CodeMender hook was found."

# Dashboard data and settings.
if [ -d "$git_dir/codemender" ]; then
  rm -rf "$git_dir/codemender"
  say "Removed the dashboard data of this repository."
fi
if git config --local --get-regexp '^codemender\.' > /dev/null 2>&1; then
  git config --local --remove-section codemender
  say "Removed the codemender.* settings of this repository."
fi

if [ -e .github/workflows/codemender.yml ]; then
  say "Kept .github/workflows/codemender.yml. Delete it yourself if you don't need it."
fi
say "The cm CLI and the records in ~/.codemender were not touched."
