#!/usr/bin/env python3
"""Local test of the Mac receiver: python3 mac/test_receiver.py
Runs a copy of healthbridge.py with a temp config, data dir and free port; never touches your real receiver or data.
Needs the receiver's own dependency: pip install cryptography"""
import hashlib, json, os, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

tmp = Path(tempfile.mkdtemp(prefix="hbtest-"))
(tmp / "mac").mkdir(); (tmp / "ios/HealthBridge").mkdir(parents=True)  # init writes the app config next to mac/
shutil.copy(Path(__file__).with_name("healthbridge.py"), tmp / "mac/healthbridge.py")
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
data = tmp / "data"; data.mkdir()
cfgp = tmp / "config.json"
SECRET = "test-secret-123"
cfgp.write_text(json.dumps({"secret": SECRET, "port": port, "bind": "127.0.0.1", "data_dir": str(data),
                            "archive_path": str(tmp / "archive.md"), "post_sync_cmd": ["true"]}))
os.chmod(cfgp, 0o600)
env = {**os.environ, "HEALTHBRIDGE_CONFIG": str(cfgp)}
proc = subprocess.Popen([sys.executable, str(tmp / "mac/healthbridge.py"), "serve"], env=env,
                        stderr=subprocess.PIPE, stdout=subprocess.DEVNULL)
key = hashlib.sha256(SECRET.encode()).digest()
results = []


def check(name, ok):
    results.append(bool(ok)); print(("PASS " if ok else "FAIL ") + name)


def post(days, sent_at=None, k=key, plain=False):
    body = json.dumps({"sent_at": sent_at or int(time.time()), "days": days}).encode()
    if plain:
        raw = body
    else:
        n = os.urandom(12); raw = n + AESGCM(k).encrypt(n, body, None)
    req = urllib.request.Request(f"http://127.0.0.1:{port}/health", data=raw, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""


def day(date):
    return json.loads((data / f"{date}.json").read_text())


for _ in range(150):
    try:
        socket.create_connection(("127.0.0.1", port), 0.2).close(); break
    except OSError:
        if proc.poll() is not None:
            sys.exit("receiver exited: " + proc.stderr.read().decode()[-800:])
        time.sleep(0.1)
else:
    proc.kill(); sys.exit("receiver never listened: " + proc.stderr.read().decode()[-800:])

try:
    now = int(time.time())
    st, ack = post([{"date": "2026-11-01", "steps": 5000, "workouts": []}], now)
    check("valid post -> 200", st == 200)
    try:
        check("sealed ack decrypts to own sent_at", json.loads(AESGCM(key).decrypt(ack[:12], ack[12:], None)).get("ack") == now)
    except Exception:
        check("sealed ack decrypts to own sent_at", False)
    post([{"date": "2026-11-01", "workouts": []}], now + 1)
    check("empty day does not erase recorded day", day("2026-11-01").get("steps") == 5000)
    post([{"date": "2026-11-01", "steps": 6000, "workouts": []}], now + 2)
    check("newer payload overwrites", day("2026-11-01").get("steps") == 6000)
    post([{"date": "2026-11-01", "steps": 1, "workouts": []}], now - 5)
    check("older payload ignored", day("2026-11-01").get("steps") == 6000)
    post([{"date": "2026-11-02", "water_ml": 500, "moods": [{"valence": 0.3}]}], now)
    check("new-field-only day (water/moods) counts as data", day("2026-11-02").get("water_ml") == 500)
    check("wrong key -> 401", post([{"date": "2026-11-03", "steps": 1}], now, k=os.urandom(32))[0] == 401)
    check("plaintext -> 401", post([{"date": "2026-11-03", "steps": 1}], now, plain=True)[0] == 401)
    check("stale sent_at -> 401", post([{"date": "2026-11-03", "steps": 1}], now - 3600)[0] == 401)

    bad = 0
    for r in range(30):
        base = now + 100 + r * 10
        ths = [threading.Thread(target=post, args=([{"date": "2026-11-05", "steps": base + i, "workouts": []}], base + i))
               for i in range(4)]
        for t in ths: t.start()
        for t in ths: t.join()
        if day("2026-11-05").get("steps") != base + 3:
            bad += 1
    check(f"race: 30x4 concurrent posts, newest wins (lost {bad}/30)", bad == 0)

    # Meals, check-ins and notes live only in the app that logged them (90 days on the phone). A reinstall, a new
    # phone or a backfill resends earlier days without them; the Mac copy must survive. Today stays the phone's
    # call, so a swipe-to-undo still reaches the Mac.
    t0 = now + 450
    today = time.strftime("%Y-%m-%d", time.localtime(t0))
    yday = time.strftime("%Y-%m-%d", time.localtime(t0 - 86400))
    n1 = {"time": f"{yday}T08:00:00+08:00", "label": "🎙 knee fine today"}
    n2 = {"time": f"{yday}T21:00:00+08:00", "label": "early night"}
    m1 = {"time": f"{yday}T12:30:00+08:00", "label": "lunch: noodles"}
    c1 = {"time": f"{yday}T07:10:00+08:00", "label": "meds"}
    post([{"date": yday, "steps": 100, "workouts": [], "notes": [n1], "meals": [m1], "checkins": [c1]}], t0)
    post([{"date": yday, "steps": 200, "workouts": []}], t0 + 1)
    d = day(yday)
    check("earlier day: logged entries the phone no longer has are kept",
          d.get("steps") == 200 and d.get("notes") == [n1] and d.get("meals") == [m1] and d.get("checkins") == [c1])
    post([{"date": yday, "steps": 300, "workouts": [], "notes": [n2]}], t0 + 2)
    check("earlier day: kept and new entries merged in time order", day(yday).get("notes") == [n1, n2])
    post([{"date": yday, "steps": 310, "workouts": [], "notes": [n1, n2]}], t0 + 3)
    check("earlier day: an entry the phone still has is not doubled", day(yday).get("notes") == [n1, n2])
    old = {"time": "2016-11-22T09:00:00+08:00", "label": "outside"}
    post([{"date": "2016-11-22", "steps": 4000, "workouts": [], "checkins": [old]}], t0 + 4)
    post([{"date": "2016-11-22", "steps": 4100, "workouts": []}], t0 + 5)
    check("backfill of an old day keeps its check-ins", day("2016-11-22").get("checkins") == [old])
    t1 = {"time": f"{today}T00:00:01+08:00", "label": "typo"}
    post([{"date": today, "steps": 50, "workouts": [], "notes": [t1]}], t0 + 6)
    post([{"date": today, "steps": 60, "workouts": []}], t0 + 7)
    check("today: undo on the phone reaches the Mac", "notes" not in day(today))
    # "Today" is the phone's date (each day's generated_at), not the Mac's: they differ across time zones.
    x = {"time": "2026-10-10T20:00:00+09:00", "label": "outside"}
    post([{"date": "2026-10-10", "generated_at": "2026-10-10T20:01:00+09:00", "steps": 1, "workouts": [], "checkins": [x]}], t0 + 8)
    post([{"date": "2026-10-10", "generated_at": "2026-10-11T00:30:00+09:00", "steps": 2, "workouts": []}], t0 + 9)
    check("phone's yesterday keeps its entries whatever the Mac's date", day("2026-10-10").get("checkins") == [x])
    y = {"time": "2026-10-12T23:00:00-08:00", "label": "typo"}
    post([{"date": "2026-10-12", "generated_at": "2026-10-12T23:01:00-08:00", "steps": 1, "workouts": [], "notes": [y]}], t0 + 10)
    post([{"date": "2026-10-12", "generated_at": "2026-10-12T23:30:00-08:00", "steps": 2, "workouts": []}], t0 + 11)
    check("undo on the phone's today applies even when the Mac is a day ahead", "notes" not in day("2026-10-12"))
    lunch8 = {"time": "2026-10-13T12:00:00+08:00", "label": "lunch"}
    lunch9 = {"time": "2026-10-13T13:00:00+09:00", "label": "lunch"}  # same moment, phone moved one zone east
    post([{"date": "2026-10-13", "steps": 1, "workouts": [], "meals": [lunch8]}], t0 + 12)
    post([{"date": "2026-10-13", "steps": 2, "workouts": [], "meals": [lunch9]}], t0 + 13)
    check("an entry re-sent in another time zone is not doubled", day("2026-10-13").get("meals") == [lunch9])
finally:
    proc.terminate(); proc.wait(5)

r = subprocess.run([sys.executable, str(tmp / "mac/healthbridge.py"), "init", "--force"], env=env, capture_output=True, text=True)
c = json.loads(cfgp.read_text())
check("init --force keeps port/bind/data_dir/post_sync_cmd", c.get("port") == port and c.get("bind") == "127.0.0.1"
      and c.get("data_dir") == str(data) and c.get("post_sync_cmd") == ["true"])
check("init --force rotates secret", c.get("secret") and c.get("secret") != SECRET)
shutil.rmtree(tmp, ignore_errors=True)
print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
