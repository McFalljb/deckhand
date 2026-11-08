"""Input for the Projects tree dry run (src/project_tree_dryrun_test.odin).
Header-only read of pi's session store: for each store folder, the newest
.jsonl's FIRST LINE only, keeping only its "cwd" field (as Deckhand's
scan_projects does). Prints TSV: store_dir, cwd, newest_ns, oldest_ns.
Nothing else from any session is read or printed.
Usage: python3 -I scripts/tree-dryrun.py > /tmp/store.tsv"""
import json, os, sys
root = os.path.join(os.environ["HOME"], ".pi", "agent", "sessions")
for d in sorted(os.scandir(root), key=lambda e: e.name):
    if not d.is_dir():
        continue
    files = [f for f in os.scandir(d.path) if f.name.endswith(".jsonl") and f.is_file()]
    if not files:
        continue
    newest = max(files, key=lambda f: f.stat().st_mtime_ns)
    oldest = min(files, key=lambda f: f.stat().st_mtime_ns)
    cwd = ""
    with open(newest.path, "rb") as fh:
        line = fh.readline(64 * 1024)
    if line.endswith(b"\n"):
        try:
            v = json.loads(line)
            if isinstance(v, dict) and isinstance(v.get("cwd"), str):
                cwd = v["cwd"]
        except ValueError:
            pass
    del line
    if not cwd:  # Deckhand's lossy fallback: the folder name
        cwd = "/" + d.name.strip("-").replace("-", "/")
    if "\t" in cwd or "\n" in cwd:
        continue
    sys.stdout.write(f"{d.path}\t{cwd}\t{newest.stat().st_mtime_ns}\t{oldest.stat().st_mtime_ns}\n")
