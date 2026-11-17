# CodeMender Starter Kit: Full Guide

Run one command in a git repository you already have, and CodeMender becomes part of your daily workflow:

- **On your machine:** every `git commit` checks the staged changes first.
- **On GitHub:** every pull request is checked. If the check finds a high-severity issue, it fails and opens a pull request with fixes.
- **In your browser:** a local dashboard shows the findings, the patches, and the result of each commit check.

CodeMender looks for vulnerabilities in your own source code, such as SQL injection or command injection. It does not replace a dependency (CVE) scanner.

This kit is an integration example written from the public documentation. For features, terms, and support, the [official documentation](https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/codemender) is the source of truth.

## 1. Before you start

The kit cannot set these up for you:

| You need | Details |
|---|---|
| A Google Cloud project with CodeMender enabled | CodeMender is in Public Preview for a limited set of customers. Contact your Google Cloud sales team to get access. |
| Two APIs enabled in that project | `aiplatform.googleapis.com` and `cloudresourcemanager.googleapis.com` |
| The right role | Your account has `roles/aiplatform.user` on the project. |
| Local credentials | You have run `gcloud auth application-default login`. |
| Network access | Your machine can reach `aiplatform.googleapis.com` and `artifactregistry.googleapis.com`. |
| System and tools | Linux or macOS, with `git`, `curl`, and `unzip`. The dashboard also needs `python3`. |

## 2. Install

Get the kit from the zip file or from the git repository, whichever you were given:

```bash
unzip codemender-starter.zip                        # from the zip file
git clone <repository URL> codemender-starter       # or from the git repository
```

Then sign in and install:

```bash
gcloud auth application-default login
cd /path/to/your/repo
bash /path/to/codemender-starter/install.sh --project YOUR_PROJECT_ID
```

Replace `YOUR_PROJECT_ID` with the ID of your own Google Cloud project. Keep the `codemender-starter` folder where you put it: the dashboard runs from there.

The script runs six steps and prints each one:

| Step | What it does | What it changes |
|---|---|---|
| 1 | Downloads the `cm` CLI from the official location, if you don't have it | `~/.local/bin/cm` |
| 2 | Runs `cm health` to check credentials, configuration, network, and permissions | Nothing |
| 3 | Runs `cm init` and saves your settings | `~/.codemender/`, plus `.git/info/exclude` and `.git/config` in your repository |
| 4 | Installs the commit hooks | `.git/hooks/pre-commit` and `.git/hooks/post-commit`. Existing hooks are kept and still run first. |
| 5 | Adds the GitHub Actions workflow, if the remote is on GitHub | `.github/workflows/codemender.yml`. The script does not commit it. |
| 6 | Starts the local dashboard and prints its address | A local server on `127.0.0.1`, and data under `.git/codemender/` |

The script never commits, pushes, or edits your existing code files.

If the check in step 2 fails, the script stops there and installs nothing else, so your commits are not affected. Fix the problem and run the same command again. You can run the script as many times as you like.

Useful options:

- `--fail-on CRITICAL,HIGH,MEDIUM` changes which severities block a commit. The default is `CRITICAL,HIGH`.
- `--no-hook` skips the commit hooks.
- `--github` or `--no-github` forces or skips the workflow file.
- `--no-dashboard` skips the dashboard. `--port N` picks its port. `--no-open` keeps it from opening a browser.
- `--help` lists everything.

## 3. Try it

**Open the dashboard.** The install prints its address, by default <http://localhost:8787>. On a desktop it also opens the page in your browser.

**Scan existing code.**

```bash
export GOOGLE_CLOUD_PROJECT="YOUR_PROJECT_ID"   # once per terminal
cm find src                        # scan a directory; use your own path
cm report                          # list the findings in the terminal
```

The findings appear on the dashboard about 10 seconds after the scan ends.

**Fix a finding.**

```bash
cm fix <ID>                        # ask CodeMender to patch one finding
git diff HEAD                      # review the patch, then commit it yourself
```

`cm fix` asks before it runs each command or writes a file, so expect many questions. Answer `y` to allow a step. To approve everything in advance, add `--yes --bypass-warning`.

`cm fix` works best when your project's dependencies are already installed. It runs commands in a sandbox that has no network access, so it cannot download them.

`cm fix` writes the patch into your working tree. It does not commit or push. Patches are AI-generated, so review each one and run your tests before you merge it.

Important: `cm fix` resets the working tree when it starts, and uncommitted changes are lost. Add `--no-reset` to keep them.

**Commit something.** The hook runs this command, which comes from the public documentation:

```bash
cm find . --diff --staged --fail-on=CRITICAL,HIGH --yes --bypass-warning
```

There are three possible results:

| Result | What you see |
|---|---|
| No finding at a blocking severity | The commit completes as usual. |
| A `CRITICAL` or `HIGH` finding | The commit is blocked and the findings are listed. Run `cm fix <ID> --no-reset`, review the patch, and commit again. |
| The check could not run (expired credentials, no network, and so on) | The commit is blocked with a message that there is no result. Run `cm health` to find out why. |

To skip the check once, run `git commit --no-verify`, or `CODEMENDER_SKIP=1 git commit ...`.

## 4. The local dashboard

The dashboard is a read-only page that shows, for this repository:

- the open and fixed findings, with the analysis, the vulnerable code, and the patch for each one;
- each commit check: passed, blocked, or no result, and what blocked it;
- the output of the latest commit check, live while it runs;
- recent scan and fix sessions, and your token usage.

It updates by itself after `cm find`, `cm fix`, and each commit.

```bash
cd /path/to/your/repo
bash /path/to/codemender-starter/dashboard.sh serve      # start it and print the address
bash /path/to/codemender-starter/dashboard.sh stop       # stop it
bash /path/to/codemender-starter/dashboard.sh refresh    # run the health check and update the data now
bash /path/to/codemender-starter/dashboard.sh status     # is it running, and where
```

Things to know:

- The dashboard is a viewer that comes with this kit. It is not a CodeMender product UI. Everything it shows comes from the `cm` CLI and its local records. For the official report, run `cm report --format html --open`.
- It listens on `127.0.0.1` only, so only this machine can open it. It has no endpoint that runs commands.
- If your repository is on a remote machine, forward the port from your own computer first: `ssh -N -L 8787:127.0.0.1:8787 <remote machine>`, then open <http://localhost:8787>.
- Its data lives in `.git/codemender/` inside your repository, so it never enters a commit.
- It stops when the machine restarts. Start it again with `dashboard.sh serve`.
- Each repository gets its own dashboard. A second one uses the next free port.

## 5. Add the GitHub pull request check

A `git commit` happens on the developer's machine, and the local hook can be skipped. The GitHub check runs in GitHub Actions when a pull request is opened or updated, and you can require it before merging.

The workflow file that `install.sh` adds is taken unchanged from the public documentation. It targets repositories on GitHub.com. An administrator sets it up once:

1. **Let the workflow sign in to Google Cloud.** This needs a Google Cloud project administrator. The following command only prints the required `gcloud` commands. Review them, then run them yourself:

   ```bash
   bash /path/to/codemender-starter/github/wif-commands.sh YOUR_PROJECT_ID YOUR_GITHUB_ORG YOUR_REPOSITORY
   ```

2. **Add three repository secrets** under Settings > Secrets and variables > Actions: `GCP_PROJECT_ID`, `GCP_WIF_PROVIDER`, and `GCP_WIF_SERVICE_ACCOUNT`. The end of the previous command's output shows the values.
3. **Allow GitHub Actions to create pull requests** under Settings > Actions > General > Workflow permissions. If you don't want automatic fixes, skip this step and delete the `autofix` job from the workflow.
4. **Check that code scanning is available.** Private repositories need GitHub Code Security. If it isn't available, delete the "Upload results to code scanning" step and the `security-events` and `actions` permissions of the scan job. Otherwise the check fails.
5. **Commit and push the workflow file.** Then make "CodeMender scan" a required check in your branch protection rules.

Behavior to know about, from the public documentation:

- Pull requests from forks and from Dependabot are not scanned.
- A pull request that the workflow opens with fixes is scanned only after someone with write access clicks "Approve workflows to run".
- The workflow turns off the CodeMender sandbox (`--sandbox=false`). Run it only on GitHub-hosted runners, which use a new virtual machine for each job. Don't use self-hosted runners that are reused between jobs.

For details, see [Integrate with CI/CD](https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/codemender/integrate-with-cicd).

## 6. Settings

Settings live in your repository's local git config. They are not committed.

```bash
git config --local codemender.failOn "CRITICAL,HIGH"               # severities that block a commit
git config --local codemender.failOpen true                        # let the commit through when the check cannot run
git config --local codemender.extraArgs "--diff-max-neighbors=3"   # extra flags for cm find
```

## 7. Data and security

The following comes from the public documentation. Refer to it for details.

- Reasoning runs in Google Cloud. The `cm` CLI reads files and runs commands on your machine, and sends the file contents, code snippets, and command results that the agent needs. Your source code is not uploaded in bulk.
- Commands that the agent runs execute in an OS-level sandbox on your machine. The sandbox has no network access by default.
- The hook and the workflow pass `--yes`, so the agent runs commands and writes files without asking each time. Read the Preview terms about turning off human confirmation before you use them.
- During Preview, use CodeMender for testing and evaluation only. Scan only code that you own, that you are authorized to scan, or that is open source under an OSI-approved license.

## 8. How long it takes

These numbers were measured on the open source project OWASP Juice Shop (TypeScript) with the default model. Your project will differ. Treat them as a rough guide, and expect the same operation to vary several-fold between runs.

| Operation | Time | Tokens |
|---|---|---|
| Scan one file | About 0.5 to 1 minute | 20,000 to 40,000 |
| Scan a directory of 63 files | About 13 minutes | About 3.6 million |
| Fix one finding | 5 to 20 minutes | 0.3 to 2 million |
| Check at commit time | Under 1 minute to 6 minutes | 20,000 to 950,000 |

The commit-time check also reviews files affected by your change, up to 10 by default. It is slower when you change a file that many other files use. Run `cm stats` at any time to see your token usage.

A check that takes minutes is slow for every commit. One option is to require only the GitHub check, and leave the local hook to developers who want earlier feedback. To install without the hooks, add `--no-hook`.

## 9. Update or uninstall

**Update.** If you cloned the repository, get the latest version and install it again. The install reuses your saved project ID and reinstalls the hooks. Restart the dashboard so that it runs the new version.

```bash
git -C /path/to/codemender-starter pull
cd /path/to/your/repo
bash /path/to/codemender-starter/install.sh
bash /path/to/codemender-starter/dashboard.sh stop
bash /path/to/codemender-starter/dashboard.sh serve
```

If you use the zip file, replace the `codemender-starter` folder with the new one, then run the last four commands.

**Uninstall.**

```bash
cd /path/to/your/repo
bash /path/to/codemender-starter/uninstall.sh
```

This stops the dashboard, removes the hooks, restores the hooks you had before, and removes the `codemender.*` settings and the dashboard data from the repository. It leaves the `cm` CLI, the records in `~/.codemender`, and the workflow file in place.

## 10. Troubleshooting

Exit codes of `cm health` and `cm find`:

| Code | Meaning | What to do |
|---|---|---|
| 0 | Success | |
| 1 | A finding at a blocking severity | `cm report --status=OPEN` |
| 10 | No usable credentials or project ID | Run `gcloud auth application-default login` and set `GOOGLE_CLOUD_PROJECT`. |
| 20 | Configuration problem | Check `~/.codemender/config.yaml`. |
| 30 | Network unreachable | Check the network or proxy to `aiplatform.googleapis.com`. |
| 40 | Not authorized | Confirm that CodeMender is enabled for the project and that your account has `roles/aiplatform.user`. |
| 50 | Timeout or budget exhausted | Retry, or scan a smaller scope. |
| 60 | Service capacity | Retry later. |

If the dashboard page says it cannot read its data, the server has stopped. Run `dashboard.sh serve` again.

## 11. What was tested

- The local part was tested on Linux x86_64 against the real CodeMender service, starting from the zip file: install, health check, a scan, a fix, a commit that passes, a commit that is blocked, skipping a check, keeping an existing hook, the dashboard, and uninstall.
- Getting the kit with `git clone` and the update steps were also tested: clone, install, a commit check, pull, install again, and restarting the dashboard.
- macOS was not tested.
- The GitHub Actions part was not tested. The workflow and the sign-in commands come from the public documentation.

Try the whole flow in a test repository before you rely on it.

## 12. What's in the kit

```
install.sh                 One-command setup
uninstall.sh               Undo the setup
dashboard.sh               Start, stop, or refresh the local dashboard
hooks/pre-commit           Checks staged changes before each commit; copied into .git/hooks/
hooks/post-commit          Tells the dashboard which commit a passed check produced
dashboard/index.html       The dashboard page
dashboard/export.py        Turns cm output into the data the page reads
dashboard/serve.py         The local read-only web server
github/codemender.yml      GitHub Actions workflow from the public documentation
github/wif-commands.sh     Prints the gcloud commands that let GitHub sign in to Google Cloud
README.md                  Quick start
GUIDE.md                   This guide
```

## 13. References

- [CodeMender overview](https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/codemender)
- [Install and configure the CLI](https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/codemender/set-up-environment)
- [Integrate with CI/CD](https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/codemender/integrate-with-cicd)
