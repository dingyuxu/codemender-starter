# Maintaining the starter kit

This file is for maintainers. It is not part of the archives that are handed out.

## Layout

- `README.md` is the quick start. `GUIDE.md` is the full guide. Keep the commands in both in sync.
- `install.sh`, `uninstall.sh`, and `dashboard.sh` are the entry points.
- `hooks/` holds the git hooks that `install.sh` copies into a repository.
- `dashboard/` holds the viewer page, the exporter, and the local server.
- `github/codemender.yml` is copied unchanged from the public documentation ("Integrate with CI/CD"). When that page changes, replace the file body; don't edit it by hand.

## The repository URL

`README.md` and `GUIDE.md` say `git clone <repository URL> codemender-starter`. When the repository has a home that the people you hand the kit to can read, replace `<repository URL>` in both files with the real address. Until then, tell them the address when you share it.

## Build the archives

```bash
bash package.sh
```

This writes `dist/codemender-starter.zip` and `dist/codemender-starter.tar.gz` from the last commit. `dist/` is not committed.

## Before you hand out a new version

1. Run the README from the zip in a new, empty test repository: unpack, install, `cm find`, `cm fix`, commit, dashboard, uninstall.
2. Check a commit that should pass and one that should be blocked.
3. Check that no file contains project IDs, host names, user names, or links that are specific to your own environment.
4. If a step, a flag, or a message changed, update `README.md` and `GUIDE.md`, including the "What was tested" section of the guide.

## Known gaps

- macOS has not been tested.
- The GitHub Actions workflow and `github/wif-commands.sh` have not been run end to end.
