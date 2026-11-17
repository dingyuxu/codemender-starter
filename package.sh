#!/usr/bin/env bash
# Builds the archives that are handed out: dist/codemender-starter.zip and
# dist/codemender-starter.tar.gz.
#
# The archives are made with `git archive` from the last commit, so they contain
# exactly the committed files and keep the executable bits. Files marked
# export-ignore in .gitattributes (this script, MAINTAINING.md, the git dotfiles)
# are left out.
#
# Usage: bash package.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [ -n "$(git status --porcelain)" ]; then
  echo "Note: there are uncommitted changes. They are NOT in the archives; commit first to include them." >&2
fi

mkdir -p dist
git archive --format=zip    --prefix=codemender-starter/ -o dist/codemender-starter.zip    HEAD
git archive --format=tar.gz --prefix=codemender-starter/ -o dist/codemender-starter.tar.gz HEAD

echo "Built from commit $(git rev-parse --short HEAD):"
ls -l dist/codemender-starter.zip dist/codemender-starter.tar.gz
