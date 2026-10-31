#!/usr/bin/env python3
"""HealthBridge Mac side: receive encrypted Apple Health data from your iPhone and build an archive.

Commands:
  doctor   read-only readiness check (stdlib only; works before dependencies are installed)
  init     create the shared secret + config, and write the iOS app's Config.swift / Local.xcconfig
  serve    run the receiver (AES-256-GCM sealed JSON over your home Wi-Fi)
  archive  rebuild the Markdown archive from the daily JSON files
  context  print a health background in Markdown to paste into any AI chat (baselines, recent changes, unusual days, training)
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
        cfg = {**DEFAULTS, "secret": secrets.token_urlsafe(32)}
        write_private(CONFIG, json.dumps({k: cfg[k] for k in ("secret", "port", "bind", "lang", "data_dir", "archive_path")}, indent=2))
        print(f"wrote {CONFIG} (mode 600)")
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
    import hashlib
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    cfg = load_config()
    if not cfg or not cfg.get("secret"):
        sys.exit(f"no secret in {CONFIG}; run: python3 mac/healthbridge.py init")
    key = hashlib.sha256(cfg["secret"].encode()).digest()
    out = Path(os.path.expanduser(cfg["data_dir"]))

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
                for day in days:
                    path = out / f"{day['date']}.json"
                    try:
                        if json.loads(path.read_text()).get("_sent_at", 0) >= sent_at:
                            continue  # replay or older payload: keep the newer data
                    except (FileNotFoundError, ValueError):
                        pass  # missing or unreadable file: overwrite
                    write_private(path, json.dumps({**day, "_sent_at": sent_at}, ensure_ascii=False, indent=2))
            except Exception as e:
                sys.stderr.write(f"write failed: {e}\n")
                return self.send_error(500)
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
            schedule_archive()

        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    import threading
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


# ---------------------------------------------------------------- context
# (key, English label, 中文名, unit, divisor, decimals)
METRICS = [("resting_hr_avg", "Resting HR", "静息心率", "bpm", 1, 0), ("hrv_sdnn_ms", "HRV (SDNN)", "心率变异性 HRV", "ms", 1, 0),
           ("walking_hr_avg", "Walking HR", "步行心率", "bpm", 1, 0), ("sleep_min", "Sleep", "睡眠", "h", 60, 1),
           ("deep_min", "Deep sleep", "深睡", "min", 1, 0), ("rem_min", "REM sleep", "REM 睡眠", "min", 1, 0),
           ("steps", "Steps", "步数", "", 1, 0), ("active_kcal", "Active energy", "活动消耗", "kcal", 1, 0),
           ("exercise_min", "Exercise", "锻炼", "min", 1, 0), ("spo2_pct", "Blood oxygen", "血氧", "%", 1, 1),
           ("resp_rate", "Respiratory rate", "呼吸频率", "/min", 1, 1), ("vo2max", "VO₂ max", "最大摄氧量 VO₂max", "ml/kg·min", 1, 1),
           ("bp_sys", "Systolic BP", "收缩压", "mmHg", 1, 0), ("bp_dia", "Diastolic BP", "舒张压", "mmHg", 1, 0),
           ("weight_kg", "Weight", "体重", "kg", 1, 1)]
# Daily totals that are still growing on the current day; flags only look at body signals, not activity
PARTIAL = {"steps", "active_kcal", "exercise_min"}
FLAGGED = {"resting_hr_avg", "hrv_sdnn_ms", "walking_hr_avg", "sleep_min", "deep_min", "rem_min", "spo2_pct", "resp_rate", "bp_sys", "bp_dia"}
LONG_TERM = ["resting_hr_avg", "hrv_sdnn_ms", "vo2max", "steps", "sleep_min", "weight_kg"]
CTX = {
    "en": {"title": "My health context (for AI)",
           "intro": ["Personal health data summarised by HealthBridge from Apple Health. Use it as background when answering my health questions.",
                     "It is not a diagnosis. Point out what deserves a doctor's attention, and say when the data is too thin to tell."],
           "meta": "Data through {end} ({stale}); {n} of the last {days} days have data. Generated {now}.",
           "fresh": "up to date", "stale": "last sync {k} days ago",
           "profile": "About me (self-reported)", "now": "Recent vs baseline",
           "nh": "| Metric | Last 7 days | Last 30 days | Last {days} days | 7 days vs baseline |",
           "note": "Baseline = the {days}-day window excluding the last 7 days. Today's steps/energy/exercise are left out until the day is over.",
           "flags": "Unusual days (last 14 days, ≥2 SD from baseline)", "noflags": "None.",
           "fh": "| Date | Metric | Value | Baseline (±1 SD) |",
           "years": "Long-term trend (yearly averages)", "year": "Year",
           "train": "Training, last 30 days", "th": "| Type | Sessions | Hours | Avg HR |",
           "weeks": "Weekly training load (last 8 weeks)", "wkh": "| Week starting | Sessions | Hours | Active kcal from workouts |",
           "notrain": "No workouts recorded."},
    "zh": {"title": "我的健康背景（给 AI 看）",
           "intro": ["以下是 HealthBridge 从 Apple Health 汇总的个人健康数据，请在回答我的健康问题时作为背景参考。",
                     "它不是诊断。请指出哪些情况值得找医生，数据不足以判断时直接说明。"],
           "meta": "数据截至 {end}（{stale}），近 {days} 天中有 {n} 天有数据。生成于 {now}。",
           "fresh": "已是最新", "stale": "距上次同步 {k} 天",
           "profile": "关于我（自填）", "now": "近期与基线对比",
           "nh": "| 指标 | 近 7 天 | 近 30 天 | 近 {days} 天 | 近 7 天 vs 基线 |",
           "note": "基线 = 近 {days} 天去掉最近 7 天。当天的步数/活动消耗/锻炼未满一天，不计入。",
           "flags": "异常日（近 14 天，偏离基线 ≥2 个标准差）", "noflags": "无。",
           "fh": "| 日期 | 指标 | 数值 | 基线（±1 标准差） |",
           "years": "长期趋势（年均值）", "year": "年份",
           "train": "近 30 天训练", "th": "| 类型 | 次数 | 时长 h | 平均心率 |",
           "weeks": "近 8 周训练量", "wkh": "| 周起始 | 次数 | 时长 h | 训练活动消耗 kcal |",
           "notrain": "没有训练记录。"},
}


def context(days=90, out=None, profile=None):
    import datetime as dt, statistics
    from collections import defaultdict
    cfg = load_config() or DEFAULTS
    lang = cfg.get("lang", "en") if cfg.get("lang") in CTX else "en"
    t = CTX[lang]
    src = Path(os.path.expanduser(cfg["data_dir"]))
    by_date = {p.stem: json.loads(p.read_text()) for p in sorted(src.glob("*.json")) if DATE_RE.fullmatch(p.stem)}
    if not by_date:
        sys.exit(f"no data in {src}")
    end = dt.date.fromisoformat(max(by_date))
    if end == dt.date.today():  # today's activity totals are incomplete
        by_date[end.isoformat()] = {k: v for k, v in by_date[end.isoformat()].items() if k not in PARTIAL}
    def window(n, skip=0):
        return [by_date[k] for k in ((end - dt.timedelta(days=i)).isoformat() for i in range(skip, n)) if k in by_date]
    def vals(ds, key):
        return [d[key] for d in ds if isinstance(d.get(key), (int, float))]
    def show(v, div, dec):
        if v is None:
            return "—"
        v = v / div
        return f"{v:,.{dec}f}" if dec else f"{round(v):,}"
    def avg(ds, key):
        xs = vals(ds, key)
        return statistics.mean(xs) if xs else None
    label = lambda m: m[2] if lang == "zh" else m[1]
    unit = lambda m: f" {m[3]}" if m[3] else ""
    sep = lambda header: "|" + "---|" * (header.count("|") - 1)
    recent, base = window(7), window(days, skip=7)
    stale_days = (dt.date.today() - end).days
    lines = [f"# {t['title']}", "", *t["intro"], "",
             t["meta"].format(end=end, days=days, n=len(window(days)), now=dt.datetime.now().strftime("%Y-%m-%d %H:%M"),
                              stale=t["fresh"] if stale_days <= 1 else t["stale"].format(k=stale_days)), ""]
    profile = Path(os.path.expanduser(profile or cfg.get("profile_path") or CONFIG.parent / "profile.md"))
    notes = re.sub(r"<!--.*?-->", "", profile.read_text(), flags=re.S).strip() if profile.exists() else ""
    if notes:
        lines += [f"## {t['profile']}", "", notes, ""]
    nh = t["nh"].format(days=days)
    lines += [f"## {t['now']}", "", nh, sep(nh)]
    for m in METRICS:
        key, div, dec = m[0], m[4], m[5]
        if not vals(window(days), key):
            continue
        r, b = avg(recent, key), avg(base, key)
        delta = f"{(r - b) / b * 100:+.0f}%" if r is not None and b else "—"
        lines.append(f"| {label(m)}{unit(m)} | {show(r, div, dec)} | {show(avg(window(30), key), div, dec)} | "
                     f"{show(avg(window(days), key), div, dec)} | {delta} |")
    lines += ["", t["note"].format(days=days), "", f"## {t['flags']}", ""]
    flags = []
    for m in METRICS:
        key, div, dec = m[0], m[4], m[5]
        if key not in FLAGGED:
            continue
        xs = vals(window(days, skip=14), key)
        if len(xs) < 14:
            continue
        mu, sd = statistics.mean(xs), statistics.pstdev(xs)
        if not sd:
            continue
        for d in window(14):
            v = d.get(key)
            if isinstance(v, (int, float)) and abs(v - mu) / sd >= 2:
                flags.append((d["date"], f"{label(m)}{unit(m)}", show(v, div, dec), f"{show(mu, div, dec)} (±{show(sd, div, dec)})"))
    if flags:
        lines += [t["fh"], sep(t["fh"])] + [f"| {' | '.join(f)} |" for f in sorted(flags, reverse=True)]
    else:
        lines.append(t["noflags"])
    years = defaultdict(list)
    for k, d in by_date.items():
        years[k[:4]].append(d)
    shown = [m for m in METRICS if m[0] in LONG_TERM and any(vals(ds, m[0]) for ds in years.values())]
    yh = f"| {t['year']} | " + " | ".join(f"{label(m)}{unit(m)}" for m in shown) + " |"
    lines += ["", f"## {t['years']}", "", yh, sep(yh)]
    for y in sorted(years, reverse=True)[:10]:
        lines.append(f"| {y} | " + " | ".join(show(avg(years[y], m[0]), m[4], m[5]) for m in shown) + " |")
    def kind(w):
        name = TYPES.get(w.get("type"))
        return (name[1] if lang == "zh" else name[0]) if name else f"#{w.get('type')}"
    lines += ["", f"## {t['train']}", ""]
    ws = [w for d in window(30) for w in d.get("workouts", [])]
    if ws:
        groups = defaultdict(list)
        for w in ws:
            groups[kind(w)].append(w)
        lines += [t["th"], sep(t["th"])]
        for k, g in sorted(groups.items(), key=lambda kv: -sum(w.get("minutes", 0) for w in kv[1])):
            hr = [w["hr_avg"] for w in g if w.get("hr_avg")]
            lines.append(f"| {k} | {len(g)} | {sum(w.get('minutes', 0) for w in g) / 60:.1f} | {round(statistics.mean(hr)) if hr else '—'} |")
        monday = end - dt.timedelta(days=end.weekday())
        lines += ["", f"### {t['weeks']}", "", t["wkh"], sep(t["wkh"])]
        for i in range(8):
            start = monday - dt.timedelta(weeks=i)
            g = [w for j in range(7) for w in by_date.get((start + dt.timedelta(days=j)).isoformat(), {}).get("workouts", [])]
            lines.append(f"| {start} | {len(g)} | {sum(w.get('minutes', 0) for w in g) / 60:.1f} | "
                         f"{round(sum(w.get('active_kcal') or 0 for w in g)):,} |")
    else:
        lines.append(t["notrain"])
    text = "\n".join(lines) + "\n"
    if out:
        write_private(Path(os.path.expanduser(out)), text)
        print(f"wrote {out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("doctor"); d.add_argument("--json", action="store_true")
    i = sub.add_parser("init"); i.add_argument("--team", help="Apple Developer Team ID"); i.add_argument("--bundle-id"); i.add_argument("--force", action="store_true", help="rotate the secret")
    sub.add_parser("serve"); sub.add_parser("archive")
    c = sub.add_parser("context", help="health background Markdown to paste into an AI chat")
    c.add_argument("--days", type=int, default=90, help="baseline window in days (default 90)")
    c.add_argument("--out", help="write to this file instead of stdout")
    c.add_argument("--profile", help="your self-written notes to include (default: profile.md next to the config)")
    a = ap.parse_args()
    if a.cmd == "doctor": sys.exit(doctor(a.json))
    if a.cmd == "init": sys.exit(init(a.team, a.bundle_id, a.force))
    if a.cmd == "serve": serve()
    if a.cmd == "archive": sys.exit(archive())
    if a.cmd == "context": sys.exit(context(a.days, a.out, a.profile))


if __name__ == "__main__":
    main()
