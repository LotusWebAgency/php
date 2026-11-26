#!/usr/bin/env python3
"""Helpers for tests/bench-apps.sh.

  apps.py json <out.json> key=value | key:=<json> ...   merge (dotted keys nest) into a JSON file
  apps.py verify <probe.json> <env-file> <php> [mode-env]  fail unless the probe shows the env file's opcache/JIT
                                                         settings are what the running php-fpm uses; prints
                                                         "unverified: VAR" for mode-env vars a probe cannot prove
  apps.py modes                                          NUL-separated name, env pairs on stdin -> modes JSON
                                                         (with the unverified vars of each); fails on an unknown PHP_OPCACHE_* var
  apps.py report <run-dir>                               results.json, results.csv, summary.md from the raw files
"""
import csv
import json
import math
import re
import statistics
import sys
from pathlib import Path

# env var of the image's entrypoint -> (ini directive, kind). Only these can be
# proven from a probe; any other variable a mode sets is listed as unverified.
ENV_INI = {
    "PHP_OPCACHE_JIT": ("opcache.jit", "str"),
    "PHP_OPCACHE_JIT_BUFFER": ("opcache.jit_buffer_size", "bytes"),
    "PHP_OPCACHE_MEMORY": ("opcache.memory_consumption", "mb"),
    "PHP_OPCACHE_INTERNED_STRINGS": ("opcache.interned_strings_buffer", "mb"),
    "PHP_OPCACHE_ENABLE": ("opcache.enable", "bool"),
    "PHP_OPCACHE_VALIDATE_TIMESTAMPS": ("opcache.validate_timestamps", "bool"),
    "PHP_OPCACHE_REVALIDATE_FREQ": ("opcache.revalidate_freq", "int"),
    "PHP_OPCACHE_HUGE_CODE_PAGES": ("opcache.huge_code_pages", "bool"),
    "PHP_OPCACHE_PRELOAD": ("opcache.preload", "str"),
    "PHP_MEMORY_LIMIT": ("memory_limit", "bytes"),
}
JIT_OFF = {"", "0", "off", "disable", "disabled"}
NOISE_FLOOR_PCT = 1.0
MIN_PAIRS = 3
FREE_BUSY_PCT = 20.0


def norm(kind, value):
    s = str(value).strip().lower()
    if kind == "bool":
        return 1 if s in ("1", "on", "true", "yes") else 0
    if kind == "int":
        return int(s)
    if kind in ("bytes", "mb"):
        m = re.fullmatch(r"(\d+)\s*([kmg]?)b?", s)
        if not m:
            return s
        n, unit = int(m.group(1)), m.group(2)
        if kind == "mb":
            return n * {"": 1, "k": 1 / 1024, "m": 1, "g": 1024}[unit]
        return n * {"": 1, "k": 1 << 10, "m": 1 << 20, "g": 1 << 30}[unit]
    return s


def read_env(path):
    env = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
    return env


def unknown_opcache(names):
    return [v for v in names if v.startswith("PHP_OPCACHE_") and v not in ENV_INI]


def unverified(names):
    return [v for v in names if v not in ENV_INI]


def cmd_verify(probe_path, env_path, php, mode_env=""):
    try:
        probe = json.loads(Path(probe_path).read_text())
    except (OSError, ValueError) as e:
        print(f"probe unreadable: {e}")
        return 1
    env, ini, problems = read_env(env_path), probe.get("ini", {}), []
    if php and not str(probe.get("php", "")).startswith(php + "."):
        problems.append(f"php {probe.get('php')} is not {php}")
    for var in unknown_opcache(env):
        problems.append(f"{var} is not a variable the image reads")
    for var, (key, kind) in ENV_INI.items():
        if var in env and norm(kind, env[var]) != norm(kind, ini.get(key, "")):
            problems.append(f"{var}={env[var]} but {key}={ini.get(key)!r}")
    jit, enabled = probe.get("jit") or {}, norm("bool", ini.get("opcache.enable", "1"))
    buffer = norm("bytes", ini.get("opcache.jit_buffer_size", "0"))
    want_jit = bool(enabled and str(ini.get("opcache.jit", "")).lower() not in JIT_OFF and isinstance(buffer, int) and buffer > 0)
    if bool(probe.get("opcache_enabled")) != bool(enabled):
        problems.append(f"opcache.enable={ini.get('opcache.enable')} but opcache_enabled={probe.get('opcache_enabled')}")
    if bool(jit.get("on")) != want_jit:
        problems.append(f"opcache.jit={ini.get('opcache.jit')!r}, opcache.jit_buffer_size={ini.get('opcache.jit_buffer_size')!r} but jit.on={jit.get('on')}")
    elif want_jit and not jit.get("buffer_size"):
        problems.append(f"jit is on but reports an empty buffer, opcache.jit_buffer_size={ini.get('opcache.jit_buffer_size')!r}")
    for var in unverified(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)=", mode_env)):
        print(f"unverified: {var}")
    for p in problems:
        print(p)
    return 1 if problems else 0


def cmd_modes(raw):
    parts = raw.split("\0")[:-1]
    modes, bad = [], []
    for i in range(0, len(parts), 2):
        names = [kv.split("=", 1)[0] for kv in parts[i + 1].split()]
        bad += [f"mode {parts[i]}: {v} is not a variable the image reads" for v in unknown_opcache(names)]
        modes.append({"name": parts[i], "env": parts[i + 1], "unverified": unverified(names)})
    for b in bad:
        print(b, file=sys.stderr)
    if bad:
        return 1
    print(json.dumps(modes))
    return 0


def set_path(doc, dotted, value):
    keys = dotted.split(".")
    for k in keys[:-1]:
        doc = doc.setdefault(k, {})
    doc[keys[-1]] = value


def cmd_json(out, pairs):
    path = Path(out)
    doc = json.loads(path.read_text()) if path.exists() else {}
    for pair in pairs:
        key, val = pair.split("=", 1)
        if key.endswith(":"):
            set_path(doc, key[:-1], json.loads(val))
        else:
            set_path(doc, key, val)
    path.write_text(json.dumps(doc, indent=2, sort_keys=False) + "\n")


def lat_ms(s):
    m = re.fullmatch(r"([\d.]+)(us|ms|s|m)", s)
    return float(m.group(1)) * {"us": 0.001, "ms": 1, "s": 1000, "m": 60000}[m.group(2)]


def parse_wrk(path):
    t = Path(path).read_text()
    rps = re.search(r"Requests/sec:\s+([\d.]+)", t)
    p50 = re.search(r"^\s+50%\s+(\S+)", t, re.M)
    p99 = re.search(r"^\s+99%\s+(\S+)", t, re.M)
    if not (rps and p50 and p99):
        return None
    bad = re.search(r"Non-2xx or 3xx responses: (\d+)", t)
    sock = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", t)
    return {
        "rps": float(rps.group(1)), "p50_ms": lat_ms(p50.group(1)), "p99_ms": lat_ms(p99.group(1)),
        "non2xx": int(bad.group(1)) if bad else 0,
        "socket_errors": sum(int(x) for x in sock.groups()) if sock else 0,
    }


def read_kv(path):
    out = {}
    p = Path(path)
    if p.exists():
        for line in p.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k] = v
    return out


def spread_pct(vals):
    if len(vals) < 2:
        return None
    return (max(vals) - min(vals)) / 2 / statistics.mean(vals) * 100


def load(run):
    manifest = json.loads((run / "manifest.json").read_text())
    stacks, samples, blocks = [], [], []
    for stack_json in sorted(run.glob("*/stack.json")):
        sdir = stack_json.parent
        stack = json.loads(stack_json.read_text())
        stack["dir"] = sdir.name
        stacks.append(stack)
        for bdir in sorted(sdir.glob("rep*-*/")):
            meta = read_kv(bdir / "meta.txt")
            if not meta:
                continue
            base = {"stack": sdir.name, "app": stack["app"], "set": stack["set"], "php": stack["php"],
                    "mode": meta["mode"], "rep": int(meta["rep"]), "pos": int(meta["pos"])}
            block = dict(base, status=meta.get("status", "?"), gate_busy_pct=float(meta.get("gate_busy", 0)),
                         gate_state=meta.get("gate_state", ""), detail=meta.get("detail", ""))
            rss = [l.split() for l in (bdir / "rss.txt").read_text().splitlines()] if (bdir / "rss.txt").exists() else []
            rss = [r for r in rss if len(r) == 3 and r[1].isdigit() and r[2].isdigit()]
            block["workers"] = len(rss)
            block["rss_mib"] = statistics.mean(int(r[1]) for r in rss) / 1024 if rss else None
            block["pss_mib"] = statistics.mean(int(r[2]) for r in rss) / 1024 if rss else None
            try:
                post = json.loads((bdir / "probe-post.json").read_text())
                block["ini"] = post.get("ini", {})
                block["jit"] = post.get("jit")
                block["php_version"] = post.get("php")
            except (OSError, ValueError):
                pass
            blocks.append(block)
            for wrk in sorted(bdir.glob("wrk-*.txt")):
                label = wrk.stem[4:]
                res = parse_wrk(wrk)
                if res is None:
                    continue
                free = read_kv(bdir / f"busy-{label}.txt").get("free_busy")
                free = float(free) if free not in (None, "") else None
                noisy = meta.get("gate_state") == "busy" or (free is not None and free > FREE_BUSY_PCT)
                samples.append(dict(base, url=label, free_busy_pct=free, noisy=noisy, **res))
    return manifest, stacks, samples, blocks


def summarize(manifest, stacks, samples, blocks):
    modes = [m["name"] for m in manifest["modes"]]
    base_mode = modes[0]
    out = []
    for stack in stacks:
        rows = [s for s in samples if s["stack"] == stack["dir"] and s["non2xx"] == 0 and s["socket_errors"] == 0]
        urls = list(dict.fromkeys(s["url"] for s in rows))
        entry = {"stack": stack["dir"], "app": stack["app"], "set": stack["set"], "php": stack["php"],
                 "image": stack["image"]["ref"], "urls": [], "memory": []}
        for url in urls:
            base = {s["rep"]: s for s in rows if s["url"] == url and s["mode"] == base_mode}
            base_vals = [s["rps"] for s in base.values()]
            for mode in modes:
                ms = {s["rep"]: s for s in rows if s["url"] == url and s["mode"] == mode}
                if not ms:
                    continue
                vals = [s["rps"] for s in ms.values()]
                row = {"url": url, "mode": mode, "n": len(vals), "rps_mean": statistics.mean(vals),
                       "rps_spread_pct": spread_pct(vals),
                       "p50_ms": statistics.mean(s["p50_ms"] for s in ms.values()),
                       "p99_ms": statistics.mean(s["p99_ms"] for s in ms.values()),
                       "noisy_samples": sum(s["noisy"] for s in ms.values()),
                       "delta_pct": None, "delta_se_pct": None, "within_noise": None}
                if mode != base_mode:
                    paired = [100 * (ms[r]["rps"] / base[r]["rps"] - 1) for r in sorted(ms) if r in base]
                    if paired:
                        d = statistics.mean(paired)
                        noise = max([NOISE_FLOOR_PCT, spread_pct(vals) or 0, spread_pct(base_vals) or 0])
                        row["delta_pct"] = d
                        row["delta_se_pct"] = statistics.stdev(paired) / math.sqrt(len(paired)) if len(paired) > 1 else None
                        row["within_noise"] = abs(d) <= noise or any(p * d <= 0 for p in paired)
                        row["too_few"] = len(paired) < MIN_PAIRS
                entry["urls"].append(row)
        base_pss = None
        for mode in modes:
            bl = [b for b in blocks if b["stack"] == stack["dir"] and b["mode"] == mode and b.get("rss_mib") is not None
                  and b["status"] == "ok"]
            if not bl:
                continue
            m = {"mode": mode, "n": len(bl), "rss_mib": statistics.mean(b["rss_mib"] for b in bl),
                 "pss_mib": statistics.mean(b["pss_mib"] for b in bl), "workers": bl[0]["workers"]}
            base_pss = base_pss or m["pss_mib"]
            m["pss_delta_pct"] = None if mode == base_mode else 100 * (m["pss_mib"] / base_pss - 1)
            entry["memory"].append(m)
        out.append(entry)
    return out


def fmt_row(r, base_mode):
    spread = "" if r["rps_spread_pct"] is None else f"{r['rps_spread_pct']:.1f}"
    if r["mode"] == base_mode:
        delta, flag = "base", ""
    elif r["delta_pct"] is None:
        delta, flag = "no baseline", "no baseline"
    else:
        se = "" if r["delta_se_pct"] is None else f" (se {r['delta_se_pct']:.1f})"
        delta = f"{r['delta_pct']:+.1f}%{se}"
        flag = "within noise" if r["within_noise"] else "real"
        if r.get("too_few"):
            flag += f", n<{MIN_PAIRS} indicative"
    if r["noisy_samples"]:
        flag = (flag + " " if flag else "") + f"host busy x{r['noisy_samples']}"
    return r, spread, delta, flag


def markdown(manifest, stacks, summary, blocks):
    modes = manifest["modes"]
    lines = [f"# App benchmark {manifest['run_id']}", "",
             f"Git `{manifest['git']['sha'][:12]}`{' (dirty)' if manifest['git']['dirty'] else ''}, "
             f"{manifest['host']['cpu_model']}, governor {manifest['host']['governor']}, "
             f"cpusets {manifest['cpusets']}, {manifest['workers']} static workers.",
             f"wrk `{manifest['wrk']['image']}`: {manifest['wrk']['threads']} threads, {manifest['wrk']['connections']} connections. "
             f"Preset {manifest['preset']}: {manifest['reps']} reps x {manifest['duration_s']} s per URL, {manifest['warmup_s']} s warmup per URL after every mode switch, "
             f"modes interleaved, order reversed on even reps. Wall time {manifest.get('wall_s', '?')} s.", "",
             "Modes (first is the baseline):", ""]
    for m in modes:
        un = f" (unverified, not provable from a probe: {', '.join(m['unverified'])})" if m.get("unverified") else ""
        lines.append(f"- `{m['name']}`: {m['env'] or 'no overrides'}{un}")
    lines += ["", f"A delta is `within noise` when it is at most the larger of {NOISE_FLOOR_PCT:g}% and either mode's rep-to-rep half-range "
              "(the `+-%` column), or when any paired repetition disagrees in sign; `se` is the standard error of the paired per-rep deltas.", ""]
    failed = [b for b in blocks if b["status"] != "ok"]
    if failed:
        lines += ["## Failed blocks", ""] + [f"- {b['stack']} {b['mode']} rep{b['rep']}: {b['detail']}" for b in failed] + [""]
    for e in summary:
        st = next(s for s in stacks if s["dir"] == e["stack"])
        lines += [f"## {e['app']} {e['set']} on php {e['php']}", "",
                  f"`{st['image']['ref']}` {st['image']['digest']}; fixture `{st['fixture']['ref']}` {st['fixture']['digest']}", "",
                  "| URL | mode | n | req/s | +-% | p50 ms | p99 ms | delta % | note |", "|---|---|---|---|---|---|---|---|---|"]
        for r in e["urls"]:
            r, spread, delta, flag = fmt_row(r, modes[0]["name"])
            lines.append(f"| {r['url']} | {r['mode']} | {r['n']} | {r['rps_mean']:.1f} | {spread} | {r['p50_ms']:.1f} | {r['p99_ms']:.1f} | {delta} | {flag} |")
        lines += ["", "| mode | workers | RSS MiB/worker | PSS MiB/worker | delta PSS |", "|---|---|---|---|---|"]
        for m in e["memory"]:
            d = "base" if m["pss_delta_pct"] is None else f"{m['pss_delta_pct']:+.1f}%"
            lines.append(f"| {m['mode']} | {m['workers']} | {m['rss_mib']:.1f} | {m['pss_mib']:.1f} | {d} |")
        lines.append("")
    return "\n".join(lines)


def cmd_report(run):
    manifest, stacks, samples, blocks = load(run)
    summary = summarize(manifest, stacks, samples, blocks)
    (run / "results.json").write_text(json.dumps(
        {"manifest": manifest, "stacks": stacks, "blocks": blocks, "samples": samples, "summary": summary}, indent=2) + "\n")
    fields = ["app", "set", "php", "mode", "rep", "pos", "url", "rps", "p50_ms", "p99_ms", "non2xx", "socket_errors",
              "free_busy_pct", "noisy"]
    with open(run / "results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(samples)
    md = markdown(manifest, stacks, summary, blocks)
    (run / "summary.md").write_text(md + "\n")
    print(md)
    return 1 if any(b["status"] != "ok" for b in blocks) else 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "json":
        cmd_json(argv[2], argv[3:])
        return 0
    if len(argv) in (5, 6) and argv[1] == "verify":
        return cmd_verify(*argv[2:])
    if len(argv) == 2 and argv[1] == "modes":
        return cmd_modes(sys.stdin.buffer.read().decode())
    if len(argv) == 3 and argv[1] == "report":
        return cmd_report(Path(argv[2]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
