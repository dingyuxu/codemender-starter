#!/usr/bin/env bash
# Adds CodeMender to a git repository you already have. Run it inside that repository:
#
#   bash /path/to/codemender-starter/install.sh --project <Google Cloud project ID>
#
# It installs the cm CLI (if missing), runs a health check, initializes cm,
# installs the commit hooks, adds the GitHub Actions workflow, and starts the
# local dashboard. It never commits, pushes, or edits your existing code files.
# You can run it again at any time. To undo it, run uninstall.sh from the same folder.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARK="codemender-starter-hook"
# Official download location of the cm CLI (public docs: "Install and configure the CLI").
CM_BASE_URL="https://artifactregistry.googleapis.com/download/v1/projects/cmoc-prod/locations/us/repositories/codemender-cli-production/files"
DOCS_URL="https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/codemender"

project=""
fail_on="CRITICAL,HIGH"
with_hook=1
with_github="auto"
with_dashboard=1
dashboard_port=""
open_page=1
skip_health=0
bin_dir="${CODEMENDER_BIN_DIR:-$HOME/.local/bin}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'Note: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: run this inside the git repository you want to set up
  bash $KIT_DIR/install.sh --project <Google Cloud project ID> [options]

Options:
  --project ID      Google Cloud project ID. Default: the GOOGLE_CLOUD_PROJECT environment variable.
  --fail-on LIST    Severities that block a commit. Default: CRITICAL,HIGH.
  --no-hook         Do not install the commit hooks.
  --github          Add the GitHub Actions workflow (default: only when the remote is on GitHub).
  --no-github       Do not add the GitHub Actions workflow.
  --no-dashboard    Do not set up or start the local dashboard.
  --port N          Port of the local dashboard. Default: 8787, or the next free port.
  --no-open         Do not open the dashboard in a browser.
  --skip-health     Continue even if the health check fails.
  -h, --help        Show this help.

Environment:
  CODEMENDER_BIN_DIR  Where to install the cm CLI. Default: ~/.local/bin.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)       [ $# -ge 2 ] || die "--project needs a project ID."; project="$2"; shift 2 ;;
    --project=*)     project="${1#*=}"; shift ;;
    --fail-on)       [ $# -ge 2 ] || die "--fail-on needs a list of severities."; fail_on="$2"; shift 2 ;;
    --fail-on=*)     fail_on="${1#*=}"; shift ;;
    --no-hook)       with_hook=0; shift ;;
    --github)        with_github="yes"; shift ;;
    --no-github)     with_github="no"; shift ;;
    --no-dashboard)  with_dashboard=0; shift ;;
    --port)          [ $# -ge 2 ] || die "--port needs a number."; dashboard_port="$2"; shift 2 ;;
    --port=*)        dashboard_port="${1#*=}"; shift ;;
    --no-open)       open_page=0; shift ;;
    --skip-health)   skip_health=1; shift ;;
    -h | --help)     usage; exit 0 ;;
    *)               usage >&2; die "Unknown option: $1" ;;
  esac
done

for tool in git curl unzip; do
  command -v "$tool" > /dev/null 2>&1 || die "Please install $tool first."
done

repo_root="$(git rev-parse --show-toplevel 2> /dev/null)" || die "Run this script inside the git repository you want to set up."
cd "$repo_root" || die "Cannot enter the repository: $repo_root"
say "Repository: $repo_root"

# Where the project ID comes from, in order: --project, the environment, the
# value saved by an earlier run, or a prompt.
[ -n "$project" ] || project="${GOOGLE_CLOUD_PROJECT:-}"
[ -n "$project" ] || project="$(git config --get codemender.project 2> /dev/null || true)"
if [ -z "$project" ] && [ -t 0 ]; then
  read -r -p "Google Cloud project ID: " project
fi
[ -n "$project" ] || die "A Google Cloud project ID is required. Run again with --project <ID>."
export GOOGLE_CLOUD_PROJECT="$project"

# ---------------------------------------------------------------- 1. cm CLI
step "1/6 cm CLI"
install_cm() {
  local os arch name tmp
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      die "This script supports Linux and macOS only. On other systems, install cm by following $DOCS_URL/set-up-environment" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64)  arch="amd64" ;;
    arm64 | aarch64) arch="arm64" ;;
    *)               die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  name="cm-$os-$arch.zip"
  tmp="$(mktemp -d)"
  say "Downloading $name and installing it to $bin_dir/cm ..."
  if ! curl -fsSL --retry 2 -o "$tmp/$name" "$CM_BASE_URL/cm%3Astable%3A$name:download?alt=media"; then
    rm -rf "$tmp"
    die "The download failed. Check that this machine can reach artifactregistry.googleapis.com."
  fi
  unzip -q -o "$tmp/$name" -d "$tmp/cm" || { rm -rf "$tmp"; die "Could not unpack the download."; }
  mkdir -p "$bin_dir"
  mv "$tmp/cm/cm" "$bin_dir/cm" && chmod +x "$bin_dir/cm"
  rm -rf "$tmp"
}

cm_path="$(command -v cm 2> /dev/null || true)"
if [ -z "$cm_path" ] && [ -x "$bin_dir/cm" ]; then
  cm_path="$bin_dir/cm"
fi
if [ -z "$cm_path" ]; then
  install_cm
  cm_path="$bin_dir/cm"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) warn "$bin_dir is not in your PATH. To type cm directly, add this line to ~/.bashrc or ~/.zshrc: export PATH=\"$bin_dir:\$PATH\"" ;;
  esac
fi
say "cm: $cm_path ($("$cm_path" --version 2> /dev/null | head -n 1))"

# ---------------------------------------------------------------- 2. project and health check
step "2/6 Project and health check"
say "Project: $project"
say "\$ cm health"
health_rc=0
"$cm_path" health < /dev/null || health_rc=$?
if [ "$health_rc" -ne 0 ]; then
  case "$health_rc" in
    10) say "The health check failed (exit code 10): no usable credentials. Run 'gcloud auth application-default login' and try again." ;;
    20) say "The health check failed (exit code 20): the cm configuration has a problem." ;;
    30) say "The health check failed (exit code 30): cannot reach aiplatform.googleapis.com. Check your network or proxy." ;;
    40) say "The health check failed (exit code 40): this account cannot use CodeMender in project $project yet. CodeMender must be enabled for the project, and the account needs roles/aiplatform.user." ;;
    *)  say "The health check failed (exit code $health_rc)." ;;
  esac
  if [ "$skip_health" -ne 1 ]; then
    say "Fix the problem above, then run this script again. No hook was installed, so your commits are not affected."
    say "To continue anyway, add --skip-health."
    exit "$health_rc"
  fi
  warn "Continuing because of --skip-health. Until the health check passes, commit checks cannot give a result."
fi

# ---------------------------------------------------------------- 3. initialize
step "3/6 Initialize"
cm_config="${CM_HOME:-$HOME/.codemender}/config.yaml"
if [ -f "$cm_config" ]; then
  say "cm is already set up on this machine. If it asks below whether to overwrite its config, the answer given is no: your config is kept."
fi
say "\$ cm init"
"$cm_path" init < /dev/null || die "cm init failed."

# Keep the marker files and verification output that cm leaves next to scanned code
# out of commits. This only writes .git/info/exclude; your .gitignore is not changed.
exclude_file="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$exclude_file")"
for pattern in .cm_project .exploit/; do
  grep -qxF "$pattern" "$exclude_file" 2> /dev/null || printf '%s\n' "$pattern" >> "$exclude_file"
done

# Make cm fix treat the repository root as its boundary (the official GitHub workflow does the same).
if [ -f "$cm_config" ]; then
  if grep -qF "\"$repo_root\"" "$cm_config"; then
    :
  elif ! grep -q '^project_paths:' "$cm_config"; then
    printf '\nproject_paths:\n  - "%s"\n' "$repo_root" >> "$cm_config"
    say "Added the repository to project_paths in $cm_config."
  elif grep -q '^project_paths:[[:space:]]*$' "$cm_config"; then
    tmp_config="$(mktemp)"
    awk -v p="$repo_root" '{ print } /^project_paths:[[:space:]]*$/ && !done { print "  - \"" p "\""; done = 1 }' "$cm_config" > "$tmp_config" \
      && cat "$tmp_config" > "$cm_config"
    rm -f "$tmp_config"
    say "Added the repository to project_paths in $cm_config."
  else
    warn "Could not update $cm_config automatically. Please add \"$repo_root\" to its project_paths list."
  fi
fi

git config --local codemender.project "$project"
git config --local codemender.failOn "$fail_on"
git config --local codemender.cmPath "$cm_path"
git config --local codemender.kitDir "$KIT_DIR"
if [ "$with_dashboard" -eq 1 ] && ! command -v python3 > /dev/null 2>&1; then
  warn "python3 was not found, so the local dashboard is not set up."
  with_dashboard=0
fi
if [ "$with_dashboard" -eq 1 ]; then
  git config --local codemender.dashboard true
else
  git config --local codemender.dashboard false
fi

# ---------------------------------------------------------------- 4. commit hooks
step "4/6 Commit hooks"
# install_hook <name>: copies hooks/<name> into the repository, keeping any hook that was there before.
install_hook() {
  local name="$1" hooks_dir hook_file
  hooks_dir="$(git rev-parse --git-path hooks)"
  mkdir -p "$hooks_dir"
  hook_file="$hooks_dir/$name"
  if [ -e "$hook_file" ] && ! grep -q "$MARK" "$hook_file"; then
    mv "$hook_file" "$hook_file.before-codemender"
    say "Your existing $name hook was renamed to $name.before-codemender. It still runs first."
  fi
  cp "$KIT_DIR/hooks/$name" "$hook_file" && chmod +x "$hook_file"
  say "Installed: $hook_file"
}

if [ "$with_hook" -ne 1 ]; then
  say "Skipped (--no-hook)."
else
  custom_hooks="$(git config --get core.hooksPath 2> /dev/null || true)"
  if [ -n "$custom_hooks" ]; then
    # The repository manages its own hooks directory (for example husky). Leave it
    # alone: put the hooks in .git and let the owner call them.
    git_dir_abs="$(git rev-parse --absolute-git-dir)"
    cp "$KIT_DIR/hooks/pre-commit" "$git_dir_abs/codemender-pre-commit" && chmod +x "$git_dir_abs/codemender-pre-commit"
    say "This repository sets core.hooksPath=$custom_hooks, so it was not changed."
    say "Add this line to your existing pre-commit script:"
    say "  \"$git_dir_abs/codemender-pre-commit\" || exit 1"
    if [ "$with_dashboard" -eq 1 ]; then
      cp "$KIT_DIR/hooks/post-commit" "$git_dir_abs/codemender-post-commit" && chmod +x "$git_dir_abs/codemender-post-commit"
      say "For the dashboard, also add this line to your post-commit script:"
      say "  \"$git_dir_abs/codemender-post-commit\""
    fi
  else
    install_hook pre-commit
    if [ "$with_dashboard" -eq 1 ]; then
      install_hook post-commit
    fi
  fi
  say "A commit is blocked by findings at severity: $fail_on"
fi

# ---------------------------------------------------------------- 5. GitHub Actions
step "5/6 GitHub Actions (pull request check)"
workflow=".github/workflows/codemender.yml"
if [ "$with_github" = "auto" ]; then
  if git remote -v 2> /dev/null | grep -qi 'github\.com'; then
    with_github="yes"
  else
    with_github="no"
  fi
fi
if [ "$with_github" = "yes" ]; then
  if [ -e "$workflow" ]; then
    say "$workflow already exists. It was not overwritten."
  else
    mkdir -p "$(dirname "$workflow")"
    cp "$KIT_DIR/github/codemender.yml" "$workflow"
    say "Added $workflow (not committed)."
  fi
  say "An administrator must set it up once before it works. See \"Add the GitHub pull request check\" in $KIT_DIR/GUIDE.md."
elif [ ! -e "$workflow" ]; then
  say "No workflow added. To add it later, run this script again with --github."
fi

# ---------------------------------------------------------------- 6. dashboard
step "6/6 Local dashboard"
if [ "$with_dashboard" -ne 1 ]; then
  say "Skipped."
else
  dash_args=(serve)
  [ -n "$dashboard_port" ] && dash_args+=(--port "$dashboard_port")
  [ "$open_page" -eq 1 ] || dash_args+=(--no-open)
  bash "$KIT_DIR/dashboard.sh" "${dash_args[@]}" || warn "The dashboard did not start. Everything else is set up. Try: bash $KIT_DIR/dashboard.sh serve"
fi

# ---------------------------------------------------------------- done
step "Done"
cat <<EOF
You can now:
  cm find <path>                     scan existing code, for example: cm find src
  cm report                          list the findings
  cm fix <ID>                        let CodeMender patch one finding (the patch stays in your
                                     working tree for you to review and commit)
  git commit ...                     each commit checks the staged changes first

If this terminal has no project set, run first:  export GOOGLE_CLOUD_PROJECT="$project"
Dashboard:  bash $KIT_DIR/dashboard.sh serve | stop | refresh | status
Undo:       bash $KIT_DIR/uninstall.sh
EOF
