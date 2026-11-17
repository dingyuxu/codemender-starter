#!/usr/bin/env python3
"""Turn cm CLI output into the JSON files that the local dashboard reads.

Standard library only. This script never produces scan results itself. All data
comes from:
  1. cm commands (cm report, cm health, cm stats, cm find --format=json),
  2. cm's local state database, opened read-only (patches and sessions),
  3. git (branch, commits, staged files).

It works on the git repository in the current directory and keeps its files in
<git dir>/codemender/dashboard/, so nothing it writes can end up in a commit.
"""

import argparse
import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

LEGACY_PREFIX = "[LEGACY / UNTOUCHED]"
HOOK_MARK = "codemender-starter-hook"
KEEP_RECORDS = 50

# Meaning of cm exit codes other than 0 (pass) and 1 (gate tripped).
EXIT_HINTS = {
    2: "cm failed (exit code 2). This check has no result.",
    10: "Credentials problem (exit code 10): no usable Application Default Credentials or project ID.",
    20: "Configuration problem (exit code 20): check config.yaml in the CodeMender home directory.",
    30: "Network unreachable (exit code 30): cannot reach the CodeMender service.",
    40: "Not authorized (exit code 40): this account or project cannot use CodeMender yet.",
    50: "Timeout or budget exhausted (exit code 50): the scan did not finish.",
    60: "Service capacity (exit code 60): retry later.",
}


def git(*args, cwd=None):
    try:
        p = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return p.stdout.strip() if p.returncode == 0 else ""


REPO = Path(git("rev-parse", "--show-toplevel") or ".").resolve()
GIT_DIR = Path(git("rev-parse", "--absolute-git-dir") or (REPO / ".git"))
DASH = GIT_DIR / "codemender" / "dashboard"
DATA = DASH / "data"
CM_HOME = Path(os.environ.get("CM_HOME") or (Path.home() / ".codemender"))


def cfg(key, default=""):
    """Reads codemender.<key> from the repository's git config."""
    return git("config", "--get", f"codemender.{key}", cwd=REPO) or default


def gcp_project():
    return os.environ.get("GOOGLE_CLOUD_PROJECT") or cfg("project")


def cm_binary():
    path = cfg("cmPath")
    if path and os.access(path, os.X_OK):
        return path
    return shutil.which("cm") or ""


def now_iso():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text):
    try:
        return dt.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return 0


def read_json(name, default):
    try:
        return json.loads((DATA / name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def write_json(name, obj):
    """Writes atomically, so the dashboard never reads a half-written file."""
    DATA.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=DATA, prefix=f".{name}.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, DATA / name)


def run_cm(args, timeout=90):
    binary = cm_binary()
    if not binary:
        return None
    env = os.environ.copy()
    project = gcp_project()
    if project:
        env["GOOGLE_CLOUD_PROJECT"] = project
    # These are bookkeeping calls made by the dashboard exporter, not by a
    # person, so keep them out of the CLI's usage telemetry.
    env["CM_TELEMETRY_OPT_OUT"] = "1"
    try:
        return subprocess.run([binary, *args], cwd=REPO, env=env, capture_output=True,
                              text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None


def parse_json_loose(text):
    """Parses JSON, skipping any log lines printed before it."""
    text = (text or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except ValueError:
        pass
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line[:1] in "[{":
            try:
                return json.loads("\n".join(lines[i:]))
            except ValueError:
                continue
    return None


def rel_to_repo(path):
    """Returns the path relative to the repository, or None when it is outside."""
    try:
        return str(Path(path).resolve().relative_to(REPO))
    except (ValueError, OSError):
        return None


def enrich(f):
    """Adds display fields to a finding as cm reports it. Changes no facts."""
    out = dict(f)
    path = f.get("file_path") or ""
    rel = rel_to_repo(path) if path else ""
    title = f.get("title") or ""
    legacy = title.startswith(LEGACY_PREFIX)
    status = (f.get("status") or "OPEN").upper()
    out.update(
        rel_path=rel if rel is not None else path,
        in_repo=rel is not None,
        short_id=(f.get("finding_id") or "")[:8],
        legacy=legacy,
        display_title=title[len(LEGACY_PREFIX):].strip() if legacy else title,
        severity=(f.get("severity") or "").upper(),
        status=status,
        # cm's own summary counts everything except FIXED and DISMISSED as open.
        bucket=status if status in ("FIXED", "DISMISSED") else "OPEN",
        file_exists=Path(path).exists() if path else None,
    )
    return out


def slim(f):
    keys = ("finding_id", "short_id", "display_title", "severity", "rel_path",
            "start_line", "vuln_type", "legacy")
    return {k: f.get(k) for k in keys}


def load_findings():
    p = run_cm(["report", "--format", "json"])
    if p is None or p.returncode != 0:
        return []
    data = parse_json_loose(p.stdout)
    if isinstance(data, dict):
        data = data.get("findings") or []
    if not isinstance(data, list):
        return []
    findings = [enrich(f) for f in data if isinstance(f, dict)]
    # The CodeMender home directory is shared by every repository on this
    # machine. Keep only the findings that belong to this repository.
    return [f for f in findings if f["in_repo"]]


def open_state_db():
    db = CM_HOME / "state.db"
    if not db.exists():
        return None
    try:
        return sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return None


def load_patches():
    """Returns {finding_id: patch} from cm's state database (read-only).

    cm has no JSON export for patches, so this reads the table that
    `cm report --patches` and the HTML report read. If the schema ever
    changes, this returns nothing and the dashboard just shows no diff.
    """
    patches = {}
    con = open_state_db()
    if con is None:
        return patches
    try:
        rows = con.execute(
            "SELECT finding_id, status, diff, reasoning, validation_result,"
            " target_file, created_at FROM patches ORDER BY created_at"
        ).fetchall()
    except sqlite3.Error:
        return patches
    finally:
        con.close()
    for fid, status, diff, reasoning, validation, target, created in rows:
        prev = patches.get(fid)
        # Keep an applied patch over later non-applied attempts.
        if prev and prev["status"] == "applied" and status != "applied":
            continue
        patches[fid] = {
            "status": status or "",
            "diff": diff or "",
            "reasoning": reasoning or "",
            "validation_result": validation or "",
            "target_file": target or "",
            "created_at": created or "",
        }
    return patches


def load_sessions():
    """Returns this repository's recent cm sessions from the state database (read-only)."""
    con = open_state_db()
    if con is None:
        return []
    try:
        rows = con.execute(
            "SELECT session_type, status, target, created_at, updated_at,"
            " project_root, parent_session_id FROM sessions ORDER BY created_at"
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        con.close()
    sessions = []
    for kind, status, target, created, updated, root, parent in rows:
        if parent:
            continue  # per-file workers of a scan; the parent session covers them
        if rel_to_repo(root or "") != ".":
            continue  # another repository
        kind = (kind or "").upper()
        if kind == "FIND":
            shown = rel_to_repo(target or "") or ""
            shown = "repository" if shown in (".", "") else shown
        else:
            shown = (target or "")[:8]
        sessions.append({
            "at": updated or created or "",
            "kind": {"FIND": "scan", "FIX": "fix", "VERIFY": "verify"}.get(kind, kind.lower()),
            "target": shown,
            "seconds": max(0, int(parse_iso(updated) - parse_iso(created))) if created and updated else None,
            "status": (status or "").upper(),
        })
    return sessions[-KEEP_RECORDS:]


def hook_installed():
    candidates = [GIT_DIR / "codemender-pre-commit"]
    hooks_dir = git("rev-parse", "--git-path", "hooks", cwd=REPO)
    if hooks_dir:
        candidates.append((REPO / hooks_dir / "pre-commit"))
    for path in candidates:
        try:
            if path.is_file() and HOOK_MARK in path.read_text(encoding="utf-8", errors="replace"):
                return True
        except OSError:
            continue
    return False


def cmd_refresh(args):
    findings = load_findings()
    patches = load_patches()
    status_lines = [l for l in git("status", "--porcelain", cwd=REPO).splitlines() if l]
    # Files with uncommitted changes. `cm fix` resets the working tree unless it
    # gets --no-reset, so the dashboard suggests --no-reset for these.
    dirty = set()
    for line in status_lines:
        parts = line.split(None, 1)
        if len(parts) == 2:
            dirty.add(parts[1].split(" -> ")[-1].strip().strip('"'))
    for f in findings:
        patch = patches.get(f.get("finding_id"))
        if patch:
            f["patch"] = patch
        f["uncommitted"] = f.get("rel_path") in dirty
    write_json("findings.json", findings)
    write_json("activity.json", load_sessions())

    # cm's own interactive HTML report, served next to the dashboard.
    report = DASH / "report.html"
    has_report = False
    if findings:
        p = run_cm(["report", "--format", "html"])
        src = CM_HOME / "reports" / "report.html"
        if p is not None and p.returncode == 0 and src.is_file():
            shutil.copyfile(src, report)
            has_report = True
    if not has_report and report.exists():
        report.unlink()

    p = run_cm(["stats", "--json"])
    stats = parse_json_loose(p.stdout) if p is not None and p.returncode == 0 else None
    write_json("stats.json", stats if isinstance(stats, dict) else {})

    p = run_cm(["--version"], timeout=15)
    version = (p.stdout.strip().splitlines() or [""])[0] if p is not None else ""
    meta = {
        "generated_at": now_iso(),
        "cm_version": version.replace("cm version", "").strip(),
        "project": gcp_project(),
        "model": "",
        "repo_name": REPO.name,
        "repo_present": True,
        "branch": git("branch", "--show-current", cwd=REPO),
        "head": {
            "hash": git("log", "-1", "--format=%h", cwd=REPO),
            "subject": git("log", "-1", "--format=%s", cwd=REPO),
            "date": git("log", "-1", "--format=%cI", cwd=REPO),
        },
        "changed_files": len(status_lines),
        "fail_on": cfg("failOn", "CRITICAL,HIGH"),
        "hook_installed": hook_installed(),
        "html_report": has_report,
    }
    write_json("meta.json", meta)
    if not args.quiet:
        here = [f for f in findings if f.get("file_exists") is not False]
        gone = len(findings) - len(here)
        open_count = sum(1 for f in here if f["bucket"] == "OPEN")
        fixed_count = sum(1 for f in here if f["bucket"] == "FIXED")
        extra = f", plus {gone} in files that are no longer in the working tree" if gone else ""
        print(f"Dashboard data updated: {open_count} open, {fixed_count} fixed{extra}.")


def cmd_health(args):
    p = run_cm(["health", "--json"], timeout=90)
    data = parse_json_loose(p.stdout) if p is not None else None
    if not isinstance(data, dict):
        data = {
            "status": "unknown",
            "error": (p.stderr.strip() if p is not None else "cm health returned nothing."),
        }
    data["checked_at"] = now_iso()
    data["project_configured"] = bool(gcp_project())
    write_json("health.json", data)
    print(data.get("status", "unknown"))


def set_live(state, detail=""):
    write_json("live.json", {"state": state, "detail": detail,
                             "since": now_iso() if state else None})


def cmd_live(args):
    set_live(None if args.clear else args.state, args.detail or "")


def staged_files():
    out = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", cwd=REPO)
    return [l for l in out.splitlines() if l]


def cmd_check_start(args):
    checks = read_json("checks.json", [])
    now = now_iso()
    for c in checks:
        if c.get("state") == "RUNNING":
            c.update(state="DONE", result="ERROR", ended_at=now,
                     note="The check was interrupted and has no result.")
    files = staged_files()
    checks.append({
        "id": f"c{int(time.time() * 1000)}",
        "started_at": now,
        "ended_at": None,
        "state": "RUNNING",
        "result": None,
        "exit_code": None,
        "seconds": None,
        "branch": git("branch", "--show-current", cwd=REPO),
        "files": files,
        "blocking": [],
        "legacy": [],
        "other": [],
        "incomplete": False,
        "commit": None,
        "note": "",
    })
    write_json("checks.json", checks[-KEEP_RECORDS:])
    set_live("check", f"Checking {len(files)} staged file(s)")


def cmd_check_end(args):
    checks = read_json("checks.json", [])
    rec = next((c for c in reversed(checks) if c.get("state") == "RUNNING"), None)
    if rec is None:
        set_live(None)
        return
    items, incomplete = [], False
    if args.findings and Path(args.findings).is_file():
        data = parse_json_loose(Path(args.findings).read_text(encoding="utf-8", errors="replace"))
        if isinstance(data, dict):
            incomplete = bool(data.get("incomplete"))
            data = data.get("findings") or []
        if isinstance(data, list):
            items = [slim(enrich(f)) for f in data if isinstance(f, dict)]
    fail_on = {s.strip().upper() for s in cfg("failOn", "CRITICAL,HIGH").split(",") if s.strip()}
    rc = args.rc
    result = "PASS" if rc == 0 else "BLOCKED" if rc == 1 else "ERROR"
    rec.update(
        state="DONE",
        ended_at=now_iso(),
        result=result,
        exit_code=rc,
        seconds=args.seconds,
        blocking=[f for f in items if not f["legacy"] and f["severity"] in fail_on],
        legacy=[f for f in items if f["legacy"]],
        other=[f for f in items if not f["legacy"] and f["severity"] not in fail_on],
        incomplete=incomplete,
        note="" if rc in (0, 1) else EXIT_HINTS.get(rc, f"cm ended with exit code {rc}. This check has no result."),
    )
    write_json("checks.json", checks[-KEEP_RECORDS:])
    set_live(None)


def cmd_check_commit(args):
    """Called from post-commit: ties the new commit to the check that preceded it."""
    checks = read_json("checks.json", [])
    commit = {"hash": args.hash, "subject": args.subject}
    now = time.time()
    last = checks[-1] if checks else None
    if last and not last.get("commit") and last.get("result") in ("PASS", "ERROR"):
        if now - parse_iso(last.get("ended_at")) <= 120:
            last["commit"] = commit
            if last["result"] == "ERROR":
                # Only possible when codemender.failOpen=true let the commit through.
                last["note"] = ((last.get("note") or "") +
                                " The check had no result, but codemender.failOpen=true let the commit through.").strip()
            write_json("checks.json", checks[-KEEP_RECORDS:])
            return
    # A commit that no check preceded: made with --no-verify, or with the check skipped.
    stamp = now_iso()
    checks.append({
        "id": f"c{int(now * 1000)}", "started_at": stamp, "ended_at": stamp,
        "state": "DONE", "result": "SKIPPED", "exit_code": None, "seconds": 0,
        "branch": git("branch", "--show-current", cwd=REPO), "files": [],
        "blocking": [], "legacy": [], "other": [], "incomplete": False,
        "commit": commit, "note": "CodeMender did not check this commit.",
    })
    write_json("checks.json", checks[-KEEP_RECORDS:])


def cmd_print_blocking(args):
    checks = read_json("checks.json", [])
    if not checks:
        return
    for f in checks[-1].get("blocking", []):
        loc = f.get("rel_path") or ""
        if f.get("start_line"):
            loc += f":{f['start_line']}"
        print(f"   {f.get('severity', ''):<8}  {loc}")
        print(f"             {f.get('display_title', '')}  (id {f.get('short_id', '')})")


def cmd_reset_checks(args):
    """Clears the commit-check history."""
    try:
        (DATA / "checks.json").unlink()
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("refresh")
    p.add_argument("--quiet", action="store_true")
    p.set_defaults(fn=cmd_refresh)

    sub.add_parser("health").set_defaults(fn=cmd_health)

    p = sub.add_parser("live")
    p.add_argument("--state", default="")
    p.add_argument("--detail", default="")
    p.add_argument("--clear", action="store_true")
    p.set_defaults(fn=cmd_live)

    sub.add_parser("check-start").set_defaults(fn=cmd_check_start)

    p = sub.add_parser("check-end")
    p.add_argument("--rc", type=int, required=True)
    p.add_argument("--seconds", type=int, default=0)
    p.add_argument("--findings", default="")
    p.set_defaults(fn=cmd_check_end)

    p = sub.add_parser("check-commit")
    p.add_argument("--hash", required=True)
    p.add_argument("--subject", default="")
    p.set_defaults(fn=cmd_check_commit)

    sub.add_parser("print-blocking").set_defaults(fn=cmd_print_blocking)
    sub.add_parser("reset-checks").set_defaults(fn=cmd_reset_checks)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
