"""Distributed independent build of the RH formalization: scheduler.

Runs on any host that sees $SHARED. Workers (worker.sh) poll $DIST/w/<worker>/ for batch-N.json and
answer with batch-N.result.json. A module is sent out only when all its imports are in the hub
tree on the hub worker, so Lake never compiles a prerequisite itself and nothing is built twice.

    python3 -I scheduler.py            # run the scheduling loop
    python3 -I scheduler.py --status   # print progress and exit
"""
import gzip
import json
import os
import sys
import time
from pathlib import Path

SHARED = Path(os.environ["SHARED"])          # directory visible to the scheduler and all workers
DIST = SHARED / "dist"
INDEX = Path(os.environ["MODULE_INDEX"])     # modules.jsonl.gz: module, imports, depth per module
STATE = DIST / "state.json"
HUB_LIST = DIST / "hub-initial.txt"  # module names already built in the hub tree at hub start
POLL_S = 10
TARGET_BATCH_S = 360

# Per worker: {"hub": bool, "max_depth": int, "batch": int}. Exactly one hub: its tree aggregates
# every module. max_depth keeps deep modules (large import closures) on workers with the disk and
# RAM for them. See workers.example.json.
WORKERS = json.loads(Path(os.environ["WORKERS_JSON"]).read_text())
LIB_EXTS = (".olean", ".ilean", ".trace", ".olean.hash", ".ilean.hash")
IR_EXTS = (".c", ".c.hash")


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def load_graph():
    rows = [json.loads(l) for l in gzip.open(INDEX)]
    by_id = {r["id"]: r for r in rows}
    mods = {r["module"]: {"depth": r["depth"], "imports": [by_id[i]["module"] for i in r["imports"]]}
            for r in rows}
    dependents = {m: [] for m in mods}
    for m, info in mods.items():
        for d in info["imports"]:
            dependents[d].append(m)
    # height: longest chain of dependents above a module; schedule tall modules first
    height = {}
    for m in sorted(mods, key=lambda x: -mods[x]["depth"]):
        height[m] = 1 + max((height[d] for d in dependents[m]), default=0)
    return mods, dependents, height


def stem(m):
    return m.replace(".", "/")


def files_for(m):
    s = stem(m)
    return [f"lib/lean/{s}{e}" for e in LIB_EXTS] + [f"ir/{s}{e}" for e in IR_EXTS]


def closure_missing(mods, targets, has):
    """All transitive imports of `targets` that the worker does not have yet."""
    need, stack = set(), [d for t in targets for d in mods[t]["imports"]]
    while stack:
        m = stack.pop()
        if m in need or m in has:
            continue
        need.add(m)
        stack.extend(mods[m]["imports"])
    return need


class Scheduler:
    def __init__(self):
        self.mods, self.dependents, self.height = load_graph()
        st = json.loads(STATE.read_text()) if STATE.exists() else {}
        self.built = set(st.get("built", []))
        if not self.built and HUB_LIST.exists():
            self.built = {m for m in HUB_LIST.read_text().split() if m in self.mods}
        self.failed = set(st.get("failed", []))
        self.has = {w: set(st.get("has", {}).get(w, [])) for w in WORKERS}
        self.inflight = {}  # worker -> (n, modules)
        self.next_n = {w: st.get("next_n", {}).get(w, 0) for w in WORKERS}
        self.batch = {w: st.get("batch", {}).get(w, WORKERS[w]["batch"]) for w in WORKERS}
        self.rate = {}
        # modules whose imports are all built and that are not built themselves
        self.waiting = {m: sum(d not in self.built for d in info["imports"])
                        for m, info in self.mods.items() if m not in self.built}
        self.ready = {m for m, c in self.waiting.items() if c == 0}
        self.recover_inflight()

    def recover_inflight(self):
        for w in WORKERS:
            d = DIST / "w" / w
            for f in sorted(d.glob("batch-*.json")) if d.exists() else []:
                if f.name.endswith(".result.json"):
                    continue
                if not f.with_suffix(".result.json").exists():
                    b = json.loads(f.read_text())
                    self.inflight[w] = (b["n"], b["modules"])
                    self.ready -= set(b["modules"])

    def save(self):
        tmp = STATE.with_suffix(".tmp")
        tmp.write_text(json.dumps({
            "built": sorted(self.built), "failed": sorted(self.failed),
            "has": {w: sorted(s) for w, s in self.has.items() if not WORKERS[w]["hub"]},
            "next_n": self.next_n, "batch": self.batch,
        }))
        tmp.replace(STATE)

    def mark_built(self, m):
        if m in self.built:
            return
        self.built.add(m)
        self.waiting.pop(m, None)
        for d in self.dependents[m]:
            if d in self.waiting:
                self.waiting[d] -= 1
                if self.waiting[d] == 0:
                    self.ready.add(d)

    def collect(self):
        for w, (n, modules) in list(self.inflight.items()):
            res = DIST / "w" / w / f"batch-{n}.result.json"
            if not res.exists():
                continue
            r = json.loads(res.read_text())
            for m in r["built"]:
                self.mark_built(m)
            if not WORKERS[w]["hub"]:
                self.has[w] |= set(r["built"]) | set(r.get("pulled", []))
            for m in r["failed"]:
                self.failed.add(m)
                log(f"FAILED {m} on {w}")
            for m in set(modules) - set(r["built"]) - set(r["failed"]):
                self.ready.add(m)  # not attempted (e.g. lake stopped early): reschedule
            secs = max(r.get("secs", 1), 1)
            self.rate[w] = len(r["built"]) / secs
            # adapt batch size toward TARGET_BATCH_S of work
            if r["built"]:
                self.batch[w] = int(min(2000, max(50, self.rate[w] * TARGET_BATCH_S)))
            log(f"{w} batch {n}: built {len(r['built'])} failed {len(r['failed'])} in {secs:.0f}s "
                f"(pull {r.get('pull_s', 0):.0f}s build {r.get('build_s', 0):.0f}s push {r.get('push_s', 0):.0f}s)"
                f" -> next batch {self.batch[w]}")
            del self.inflight[w]
        self.save()

    def alive(self, w):
        f = DIST / "w" / w / "alive"
        return f.exists() and time.time() - f.stat().st_mtime < 300

    def dispatch(self):
        order = None
        for w, cfg in WORKERS.items():
            if w in self.inflight or not self.alive(w):
                continue
            if order is None:
                order = sorted(self.ready - self.failed, key=lambda m: -self.height[m])
            pick = [m for m in order if self.mods[m]["depth"] <= cfg["max_depth"]][: self.batch[w]]
            if not pick:
                continue
            picked = set(pick)
            order = [m for m in order if m not in picked]
            self.ready -= picked
            n = self.next_n[w] = self.next_n[w] + 1
            d = DIST / "w" / w
            d.mkdir(parents=True, exist_ok=True)
            pull = [] if cfg["hub"] else sorted(closure_missing(self.mods, pick, self.has[w]))
            (d / f"batch-{n}.pull.txt").write_text("".join(f + "\n" for m in pull for f in files_for(m)))
            (d / f"batch-{n}.push.txt").write_text("".join(f + "\n" for m in pick for f in files_for(m)))
            (d / f"batch-{n}.targets.txt").write_text("".join(f"+{m}:olean\n" for m in pick))
            tmp = d / f"batch-{n}.tmp"
            tmp.write_text(json.dumps({"n": n, "modules": pick, "pulled": pull}))
            tmp.replace(d / f"batch-{n}.json")
            self.inflight[w] = (n, pick)
            log(f"-> {w} batch {n}: {len(pick)} modules (depth {self.mods[pick[0]]['depth']}"
                f"-{self.mods[pick[-1]]['depth']}), pull {len(pull)}")

    def status(self):
        total = len(self.mods)
        return (f"built {len(self.built)}/{total} ({100 * len(self.built) / total:.1f}%), "
                f"ready {len(self.ready)}, inflight {sum(len(v[1]) for v in self.inflight.values())}, "
                f"failed {len(self.failed)}, rates/min "
                + " ".join(f"{w}={60 * r:.0f}" for w, r in self.rate.items()))

    def run(self):
        last = 0
        while len(self.built) < len(self.mods):
            self.collect()
            self.dispatch()
            if time.time() - last > 300:
                log("STATUS " + self.status())
                last = time.time()
            time.sleep(POLL_S)
        log("ALL MODULES BUILT " + self.status())
        (DIST / "ALL_BUILT").touch()


if __name__ == "__main__":
    s = Scheduler()
    if "--status" in sys.argv:
        print(s.status())
    else:
        s.run()
