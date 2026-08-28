import time, requests, os
TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11")
WEBHOOK = "http://localhost:5678/webhook/telegram"
OFFSET = 0
# Clear pending first
try:
    r = requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates", params={"offset": 0}, timeout=10)
    data = r.json()
    if data.get("result"):
        OFFSET = max(u["update_id"] for u in data["result"]) + 1
        requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates", params={"offset": OFFSET, "timeout": 1}, timeout=10)
        print(f"cleared pending, new OFFSET {OFFSET}")
    else:
        print(f"no pending, OFFSET {OFFSET}")
except Exception as e:
    print("clear failed", e)
print(f"Polling {TOKEN[:10]}... -> {WEBHOOK} OFFSET {OFFSET}", flush=True)
while True:
    try:
        r = requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates", params={"offset": OFFSET, "timeout": 30}, timeout=35)
        data = r.json()
        if not data.get("ok"):
            print("getUpdates error", data, flush=True)
            time.sleep(5)
            continue
        for upd in data.get("result", []):
            OFFSET = max(OFFSET, upd["update_id"]+1)
            try:
                pr = requests.post(WEBHOOK, json=upd, timeout=10)
                txt = upd.get("message", {}).get("text","")[:30]
                print(f"fwd {upd['update_id']} '{txt}' -> {pr.status_code} {pr.text[:80]}", flush=True)
            except Exception as e:
                print("webhook forward failed", e, flush=True)
    except Exception as e:
        print("poll error", e, flush=True)
        time.sleep(5)
