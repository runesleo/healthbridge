#!/usr/bin/env python3
"""HealthBridge Mac side: receive encrypted Apple Health data from your iPhone and build an archive.

Commands:
  doctor   read-only readiness check (stdlib only; works before dependencies are installed)
  init     create the shared secret + config, and write the iOS app's Config.swift / Local.xcconfig
  serve    run the receiver (AES-256-GCM sealed JSON over your home Wi-Fi)
  archive  rebuild the Markdown archive from the daily JSON files
"""
import argparse, json, os, re, secrets, shutil, socket, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = Path(os.environ.get("HEALTHBRIDGE_CONFIG", Path.home() / ".config/healthbridge/config.json"))
DEFAULTS = {"port": 8765, "bind": "0.0.0.0", "lang": "en",
            "data_dir": str(Path.home() / "HealthBridge/data"),
            "archive_path": str(Path.home() / "HealthBridge/archive.md")}
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
MAX_BODY = 4_000_000
FRESH_SECONDS = 600


def write_private(path, text, mode=0o600):
    """Atomically write text to path with restrictive permissions from the start."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def load_config():
    if not CONFIG.exists():
        return None
    cfg = {**DEFAULTS, **json.loads(CONFIG.read_text())}
    if cfg.get("secret_file"):  # allow keeping the secret in a separate file
        cfg["secret"] = Path(os.path.expanduser(cfg["secret_file"])).read_text().strip()
    return cfg


# ---------------------------------------------------------------- doctor
def doctor(as_json=False):
    checks = []
    def add(name, ok, fix_by="", next_cmd="", status=None):
        checks.append({"check": name, "status": status or ("OK" if ok else "MISSING"), "fix_by": "" if ok else fix_by, "next": "" if ok else next_cmd})
    add("python>=3.9", sys.version_info >= (3, 9), "user", "install Python 3.9+")
    try:
        import cryptography  # noqa: F401
        add("python package: cryptography", True)
    except ImportError:
        add("python package: cryptography", False, "agent", "python3 -m pip install --user cryptography")
    cfg = load_config()
    add(f"config {CONFIG}", cfg is not None and bool(cfg.get("secret")), "agent", "python3 mac/healthbridge.py init")
    add("ios/HealthBridge/Config.swift", (ROOT / "ios/HealthBridge/Config.swift").exists(), "agent", "python3 mac/healthbridge.py init")
    add("xcodegen", shutil.which("xcodegen") is not None, "agent", "brew install xcodegen")
    xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).returncode == 0 if shutil.which("xcodebuild") else False
    add("Xcode (xcodebuild)", xcode, "user", "install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app")
    port = int((cfg or DEFAULTS)["port"])
    bind = (cfg or DEFAULTS)["bind"]
    with socket.socket() as s:
        s.settimeout(2)
        listening = s.connect_ex(("127.0.0.1" if bind in ("0.0.0.0", "") else bind, port)) == 0
    add(f"receiver listening on :{port}", listening, "agent", "python3 mac/healthbridge.py serve")
    data_dir = Path(os.path.expanduser((cfg or DEFAULTS)["data_dir"]))
    n = len(list(data_dir.glob("*.json"))) if data_dir.exists() else 0
    add(f"received days in {data_dir}", n > 0, "user", "open HealthBridge on the iPhone and tap Sync now")
    ready = all(c["status"] == "OK" for c in checks)
    if as_json:
        print(json.dumps({"ready": ready, "days_received": n, "checks": checks}, indent=2))
    else:
        for c in checks:
            tail = f"  -> {c['fix_by']}: {c['next']}" if c["status"] != "OK" else ""
            print(f"{c['status']:8} {c['check']}{tail}")
        print("READY" if ready else "NOT READY")
    return 0 if ready else 1


# ---------------------------------------------------------------- init
def lan_ip():
    for iface in ("en0", "en1"):
        out = subprocess.run(["ipconfig", "getifaddr", iface], capture_output=True, text=True).stdout.strip()
        if out:
            return out
    return None


def init(team=None, bundle_id=None, force=False):
    cfg = load_config()
    if cfg and cfg.get("secret") and not force:
        print(f"keeping existing secret in {CONFIG}")
    else:
        # rotate only the secret: keep every other setting (port, extra_ports, post_sync_cmd, secret_file, ...)
        raw = json.loads(CONFIG.read_text()) if CONFIG.exists() else {"secret": None, **DEFAULTS}
        secret = secrets.token_urlsafe(32)
        if raw.get("secret_file"):
            write_private(Path(os.path.expanduser(raw["secret_file"])), secret + "\n")
            print(f"wrote new secret to {raw['secret_file']} (mode 600)")
        else:
            raw["secret"] = secret
            write_private(CONFIG, json.dumps(raw, indent=2))
            print(f"wrote {CONFIG} (mode 600)")
        cfg = {**DEFAULTS, **raw, "secret": secret}
    host = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True).stdout.strip() or socket.gethostname().split(".")[0]
    ip = lan_ip()
    swift = ROOT / "ios/HealthBridge/Config.swift"
    write_private(swift,
        "// Generated by `python3 mac/healthbridge.py init`. Git-ignored: contains your secret.\n"
        "enum Config {\n"
        f"    static let secret = {json.dumps(cfg['secret'])}\n"
        f"    static let endpoint = \"http://{host}.local:{cfg['port']}/health\"\n"
        f"    static let fallbackHost: String? = {json.dumps(ip) if ip else 'nil'}\n"
        f"    static let port = {cfg['port']}\n"
        "}\n")
    print(f"wrote {swift} (endpoint {host}.local, fallback {ip})")
    xc = ROOT / "ios/Local.xcconfig"
    existing = dict(re.findall(r"^\s*(\w+)\s*=\s*(\S+)", xc.read_text(), re.M)) if xc.exists() else {}
    # never change an existing bundle ID unless asked: a new ID installs a second app without Health access
    bundle_id = bundle_id or existing.get("PRODUCT_BUNDLE_IDENTIFIER") or f"com.healthbridge.{secrets.token_hex(3)}"
    team = team or existing.get("DEVELOPMENT_TEAM")
    lines = [f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id}"] + ([f"DEVELOPMENT_TEAM = {team}"] if team else [])
    xc.write_text("\n".join(lines) + "\n")
    print(f"wrote {xc} ({bundle_id}{', team ' + team if team else ', set DEVELOPMENT_TEAM or pick a team in Xcode'})")
    return 0


# ---------------------------------------------------------------- serve
def serve():
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import hashlib, threading
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    cfg = load_config()
    if not cfg or not cfg.get("secret"):
        sys.exit(f"no secret in {CONFIG}; run: python3 mac/healthbridge.py init")
    key = hashlib.sha256(cfg["secret"].encode()).digest()
    out = Path(os.path.expanduser(cfg["data_dir"]))
    write_lock = threading.Lock()  # concurrent syncs must not interleave the read-compare-write of a day file

    def has_metrics(day):
        return bool(day.get("workouts")) or any(k not in ("date", "generated_at", "workouts", "_sent_at") for k in day)

    class Handler(BaseHTTPRequestHandler):
        timeout = 15  # drop clients that connect and stall

        def do_POST(self):
            if self.path != "/health":
                return self.send_error(404)
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self.send_error(411)
            if length < 28:  # nonce + tag at minimum
                return self.send_error(400)
            if length > MAX_BODY:
                return self.send_error(413)
            raw = self.rfile.read(length)
            try:
                body = json.loads(AESGCM(key).decrypt(raw[:12], raw[12:], None))
                sent_at = int(body.get("sent_at", 0))
            except Exception:
                return self.send_error(401)
            if abs(time.time() - sent_at) > FRESH_SECONDS:
                return self.send_error(401)
            days = body.get("days", [])
            if not isinstance(days, list) or not all(isinstance(d, dict) and DATE_RE.fullmatch(str(d.get("date", ""))) for d in days):
                return self.send_error(400)  # validate everything before writing anything
            try:
                with write_lock:
                    for day in days:
                        path = out / f"{day['date']}.json"
                        try:
                            old = json.loads(path.read_text())
                        except (FileNotFoundError, ValueError):
                            old = None  # missing or unreadable file: overwrite
                        if old is not None:
                            if old.get("_sent_at", 0) >= sent_at:
                                continue  # replay or older payload: keep the newer data
                            if not has_metrics(day) and has_metrics(old):
                                sys.stderr.write(f"kept {day['date']}: incoming day is empty\n")
                                continue  # an empty read must never erase a recorded day
                        write_private(path, json.dumps({**day, "_sent_at": sent_at}, ensure_ascii=False, indent=2))
            except Exception as e:
                sys.stderr.write(f"write failed: {e}\n")
                return self.send_error(500)
            # sealed ack: the phone only counts a sync as delivered when this decrypts to its own sent_at,
            # so another service answering 200 on this address can't make it skip days
            nonce = os.urandom(12)
            ack = nonce + AESGCM(key).encrypt(nonce, json.dumps({"ack": sent_at}).encode(), None)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(ack)))
            self.end_headers(); self.wfile.write(ack)
            schedule_archive()

        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    pending = threading.Event()

    def schedule_archive():
        pending.set()  # coalesce bursts (e.g. a 10-year backfill) into one rebuild

    def archiver():
        while True:
            pending.wait()
            time.sleep(5)
            pending.clear()
            try:
                ok = subprocess.run([sys.executable, __file__, "archive"], stdout=subprocess.DEVNULL, timeout=600).returncode == 0
                if ok and hook:
                    subprocess.run([os.path.expanduser(a) for a in hook], stdout=subprocess.DEVNULL, timeout=300)
            except Exception as e:  # never let a failure stop future rebuilds
                sys.stderr.write(f"archive/hook failed: {e}\n")

    hook = cfg.get("post_sync_cmd")  # optional: your own script, run after each successful archive rebuild
    if hook is not None and not (isinstance(hook, list) and hook and all(isinstance(a, str) for a in hook)):
        sys.exit('post_sync_cmd must be a list of strings, e.g. ["python3", "~/rules.py"]')
    if hook and CONFIG.stat().st_mode & 0o077:
        sys.exit(f"refusing post_sync_cmd: {CONFIG} must not be readable/writable by others (chmod 600)")
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    threading.Thread(target=archiver, daemon=True).start()
    ThreadingHTTPServer.daemon_threads = True
    # extra_ports: also listen here, e.g. when another service already holds `port` on a VPN address like Tailscale's
    for port in cfg.get("extra_ports") or []:
        srv = ThreadingHTTPServer((cfg["bind"], int(port)), Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    ports = ", ".join(str(x) for x in [cfg["port"], *(cfg.get("extra_ports") or [])])
    print(f"HealthBridge receiver on {cfg['bind']}:{ports} -> {out}", file=sys.stderr)
    ThreadingHTTPServer((cfg["bind"], int(cfg["port"])), Handler).serve_forever()


# ---------------------------------------------------------------- archive
TYPES = {2: ("Archery", "射箭"), 4: ("Badminton", "羽毛球"), 6: ("Basketball", "篮球"), 8: ("Boxing", "拳击"),
         9: ("Climbing", "攀岩"), 11: ("Cross training", "交叉训练"), 13: ("Cycling", "骑行"), 16: ("Elliptical", "椭圆机"),
         20: ("Functional strength", "功能性力量训练"), 24: ("Hiking", "徒步"), 28: ("Martial arts", "武术"),
         29: ("Mind and body", "身心训练"), 33: ("Prep and recovery", "准备与恢复"), 35: ("Rowing", "划船"),
         37: ("Running", "跑步"), 41: ("Soccer", "足球"), 43: ("Squash", "壁球"), 44: ("Stair climbing", "爬楼机"),
         46: ("Swimming", "游泳"), 47: ("Table tennis", "乒乓球"), 48: ("Tennis", "网球"),
         50: ("Traditional strength", "传统力量训练"), 52: ("Walking", "步行"), 57: ("Yoga", "瑜伽"),
         59: ("Core training", "核心训练"), 62: ("Flexibility", "柔韧训练"), 63: ("HIIT", "高强度间歇训练"),
         64: ("Jump rope", "跳绳"), 66: ("Pilates", "普拉提"), 73: ("Mixed cardio", "混合有氧"),
         76: ("Fitness gaming", "健身游戏"), 77: ("Cardio dance", "有氧舞蹈"), 79: ("Pickleball", "匹克球"),
         80: ("Cooldown", "放松整理"), 3000: ("Other", "其他")}
TEXT = {
    "en": {"title": "Apple Watch activity & heart-rate archive", "intro": "Range {a} ~ {b}, {n} days. Generated by HealthBridge; edits are overwritten.",
           "years": "By year", "months": "By month", "workouts": "All workouts (newest first)",
           "yh": "| Year | Days | Avg steps | Avg active kcal | Resting HR | HRV ms | Sleep h | Workouts | Workout hours |",
           "mh": "| Month | Avg steps | Avg active kcal | Avg exercise min | Resting HR | HRV ms | Sleep h | Workouts | Workout hours | Top workouts |",
           "wh": "| Date | Type | Start | Minutes | Avg/Max HR | Active kcal | km |"},
    "zh": {"title": "Apple Watch 运动与心率档案", "intro": "数据范围 {a} ~ {b}，共 {n} 天。由 HealthBridge 自动生成，手改会被覆盖。",
           "years": "按年汇总", "months": "按月汇总", "workouts": "全部训练记录（新到旧）",
           "yh": "| 年份 | 有数据天数 | 日均步数 | 日均活动消耗 kcal | 静息心率均值 | HRV ms | 睡眠 h | 训练次数 | 训练总时长 h |",
           "mh": "| 月份 | 日均步数 | 日均活动消耗 kcal | 日均锻炼分钟 | 静息心率均值 | HRV ms | 睡眠 h | 训练次数 | 训练总时长 h | 主要训练 |",
           "wh": "| 日期 | 类型 | 开始 | 时长 min | 平均/最高心率 | 活动消耗 kcal | 距离 km |"},
}


def archive():
    import statistics
    from collections import defaultdict
    cfg = load_config() or DEFAULTS
    lang = cfg.get("lang", "en") if cfg.get("lang") in TEXT else "en"
    t = TEXT[lang]
    src = Path(os.path.expanduser(cfg["data_dir"]))
    days = [json.loads(p.read_text()) for p in sorted(src.glob("*.json"))]
    if not days:
        sys.exit(f"no data in {src}")
    def mean(xs):
        xs = [x for x in xs if x is not None]
        return round(statistics.mean(xs)) if xs else None
    def fmt(v):
        return "—" if v is None else f"{v:,}"
    def kind(w):
        name = TYPES.get(w.get("type"))
        return (name[1] if lang == "zh" else name[0]) if name else f"#{w.get('type')}"
    def hours(ws):
        return round(sum(w.get("minutes", 0) for w in ws) / 60, 1)
    def sleep_h(ds):
        xs = [d["sleep_min"] for d in ds if d.get("sleep_min")]
        return round(statistics.mean(xs) / 60, 1) if xs else "—"
    sep = lambda header: "|" + "---|" * (header.count("|") - 1)
    lines = [f"# {t['title']}", "", t["intro"].format(a=days[0]["date"], b=days[-1]["date"], n=len(days)), "",
             f"## {t['years']}", "", t["yh"], sep(t["yh"])]
    years, months = defaultdict(list), defaultdict(list)
    for d in days:
        years[d["date"][:4]].append(d); months[d["date"][:7]].append(d)
    for y in sorted(years, reverse=True):
        ds = years[y]; ws = [w for d in ds for w in d.get("workouts", [])]
        lines.append(f"| {y} | {len(ds)} | {fmt(mean([d.get('steps') for d in ds]))} | {fmt(mean([d.get('active_kcal') for d in ds]))} | "
                     f"{fmt(mean([d.get('resting_hr_avg') for d in ds]))} | {fmt(mean([d.get('hrv_sdnn_ms') for d in ds]))} | {sleep_h(ds)} | {len(ws)} | {hours(ws)} |")
    lines += ["", f"## {t['months']}", "", t["mh"], sep(t["mh"])]
    for m in sorted(months, reverse=True):
        ds = months[m]; ws = [w for d in ds for w in d.get("workouts", [])]
        counts = defaultdict(int)
        for w in ws:
            counts[kind(w)] += 1
        top = ", ".join(f"{k}×{v}" for k, v in sorted(counts.items(), key=lambda kv: -kv[1])[:3]) or "—"
        lines.append(f"| {m} | {fmt(mean([d.get('steps') for d in ds]))} | {fmt(mean([d.get('active_kcal') for d in ds]))} | "
                     f"{fmt(mean([d.get('exercise_min') for d in ds]))} | {fmt(mean([d.get('resting_hr_avg') for d in ds]))} | "
                     f"{fmt(mean([d.get('hrv_sdnn_ms') for d in ds]))} | {sleep_h(ds)} | {len(ws)} | {hours(ws)} | {top} |")
    lines += ["", f"## {t['workouts']}", "", t["wh"], sep(t["wh"])]
    for d in reversed(days):
        for w in d.get("workouts", []):
            lines.append(f"| {d['date']} | {kind(w)} | {w.get('start', '')[11:16]} | {w.get('minutes', '—')} | "
                         f"{fmt(w.get('hr_avg'))}/{fmt(w.get('hr_max'))} | {fmt(w.get('active_kcal'))} | {w.get('km', '—')} |")
    dst = Path(os.path.expanduser(cfg["archive_path"]))
    write_private(dst, "\n".join(lines) + "\n")
    print(f"wrote {dst} ({len(days)} days)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("doctor"); d.add_argument("--json", action="store_true")
    i = sub.add_parser("init"); i.add_argument("--team", help="Apple Developer Team ID"); i.add_argument("--bundle-id"); i.add_argument("--force", action="store_true", help="rotate the secret")
    sub.add_parser("serve"); sub.add_parser("archive")
    a = ap.parse_args()
    if a.cmd == "doctor": sys.exit(doctor(a.json))
    if a.cmd == "init": sys.exit(init(a.team, a.bundle_id, a.force))
    if a.cmd == "serve": serve()
    if a.cmd == "archive": sys.exit(archive())


if __name__ == "__main__":
    main()
