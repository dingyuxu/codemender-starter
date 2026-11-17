# CodeMender Starter Kit

One command adds CodeMender to a git repository you already have:

- Every `git commit` checks the staged changes first and blocks high-severity vulnerabilities.
- A local dashboard shows the findings, the patches, and each commit check.
- Optionally, a GitHub Actions workflow checks every pull request.

This page is the quick start. For everything else, see [GUIDE.md](GUIDE.md).

## Before you start

- Linux or macOS, with `git`, `curl`, `unzip`, `python3`, and the `gcloud` CLI.
- A Google Cloud project with CodeMender enabled. CodeMender is in Public Preview for a limited set of customers; ask your Google Cloud sales team for access.
- Your account has the `roles/aiplatform.user` role on that project.

## 1. Get the kit

Use whichever you were given.

From the zip file:

```bash
unzip codemender-starter.zip
```

From the git repository, if you have access to it:

```bash
git clone https://github.com/dingyuxu/codemender-starter.git
```

Keep the `codemender-starter` folder where it is. The dashboard runs from there.

## 2. Sign in

```bash
gcloud auth application-default login
```

## 3. Install into your repository

```bash
cd /path/to/your/repo
bash /path/to/codemender-starter/install.sh --project YOUR_PROJECT_ID
```

The script prints six steps and ends with the dashboard address, by default <http://localhost:8787>. Open it in your browser.

- It never commits, pushes, or edits your code files.
- If the health check in step 2 fails, it stops and installs nothing else. Fix the problem it reports and run the same command again.
- If it says that `cm` is not in your `PATH`, add the line it prints to your shell profile, or run that line in your terminal now.

## 4. Use it

```bash
export GOOGLE_CLOUD_PROJECT="YOUR_PROJECT_ID"   # once per terminal

cm find src        # scan a directory; use your own path
cm report          # list the findings and their IDs
cm fix <ID>        # let CodeMender patch one finding
git diff HEAD      # review the patch
git add -A && git commit -m "Fix <what you fixed>"
```

What to expect:

- **`cm find`** takes from under a minute for one file to many minutes for a large directory. The findings appear on the dashboard about 10 seconds after it ends.
- **`cm fix`** asks before it runs each command or writes a file, so expect many questions. Answer `y` to allow a step. To approve everything in advance, add `--yes --bypass-warning`. A fix takes 5 to 20 minutes and leaves the patch in your working tree. It does not commit.
- **`cm fix` works best when your project's dependencies are already installed.** It runs commands in a sandbox that has no network access, so it cannot download them.
- **`cm fix` resets your working tree first**, so uncommitted changes are lost. To keep them, add `--no-reset`.
- **`git commit`** runs the check, which takes from under a minute to several minutes. Then one of three things happens:

| Result | What you see |
|---|---|
| Nothing at severity `CRITICAL` or `HIGH` | The commit completes. |
| A `CRITICAL` or `HIGH` finding | The commit is blocked and the finding is listed. Fix it, or run `cm fix <ID> --no-reset`, then commit again. |
| The check could not run | The commit is blocked with "no result". Run `cm health` to see why. |

To skip the check once: `git commit --no-verify`.

Patches are AI-generated. Review each one and run your tests before you merge it.

## 5. Dashboard

```bash
cd /path/to/your/repo
bash /path/to/codemender-starter/dashboard.sh status     # is it running, and at which address
bash /path/to/codemender-starter/dashboard.sh serve      # start it, for example after a restart
bash /path/to/codemender-starter/dashboard.sh stop       # stop it
```

The dashboard only listens on this machine (`127.0.0.1`). If your repository is on a remote machine, forward the port from your own computer first: `ssh -N -L 8787:127.0.0.1:8787 <remote machine>`.

## 6. Uninstall

```bash
cd /path/to/your/repo
bash /path/to/codemender-starter/uninstall.sh
```

This stops the dashboard, removes the hooks, and restores the hooks you had before. It leaves the `cm` CLI and its records in place.

## 7. Update the kit

If you cloned the repository, get the latest version and install it again. The install reuses your saved project ID.

```bash
git -C /path/to/codemender-starter pull
cd /path/to/your/repo
bash /path/to/codemender-starter/install.sh
bash /path/to/codemender-starter/dashboard.sh stop
bash /path/to/codemender-starter/dashboard.sh serve
```

If you use the zip file, replace the `codemender-starter` folder with the new one, then run the last four commands.

## More

[GUIDE.md](GUIDE.md) covers the GitHub pull request check, settings, what data leaves your machine, expected run times, troubleshooting, and what was tested.
