# Configuration Guide

## Host vs Bridge Networking

**Problem:** `n8n-demo` in Docker `bridge` mode fails `ECONNREFUSED 149.154.166.110:443` to `api.telegram.org` (`wget -qO- https://api.telegram.org` fails inside the container but succeeds from the host). Telegram Bot API uses `149.154.167.x` and `91.108.56.x` ranges that are blocked in some bridge configurations.

**Fix:** `docker-compose.yml` sets `network_mode: host` for `n8n`. `depends_on: postgres condition: service_healthy` still works under host mode. For host mode, Postgres and Qdrant are reachable at `127.0.0.1` instead of Docker DNS names, so `.env` uses:

```
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5433
QDRANT_URL=http://127.0.0.1:6333
DB_POSTGRESDB_HOST=127.0.0.1
DB_POSTGRESDB_PORT=5433
```

For bridge mode, use `postgres` / `qdrant` hostnames and default ports `5432` / `6333`.

Verify: `docker exec n8n-demo wget -qO- https://api.telegram.org/bot<TOKEN>/getMe` should return `{"ok":true}`. If it fails inside the container but `curl` from the host succeeds, switch to `network_mode: host`.

Healthcheck: `postgres` uses `pg_isready -U ${POSTGRES_USER:-n8n} -d ${POSTGRES_DB:-n8n}` and gates `n8n` startup. Volumes `qdrant_storage` and `pgdata` persist vectors.

## OpenRouter (Free Models) vs OpenAI

Workflows default to `inclusionai/ling-3.0-flash-fin:free` via OpenRouter (`https://openrouter.ai/api/v1/models` lists it under the free tier). Verified with:

```bash
curl -H "Authorization: Bearer $OPENAI_API_KEY" https://openrouter.ai/api/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"inclusionai/ling-3.0-flash-fin:free","messages":[{"role":"user","content":"hi"}]}'
# cost 0, response ok
```

Available at `https://openrouter.ai/api/v1/models` with `curl` verification.

In n8n, credential `openAiApi` stores `API Key: sk-or-v1-...` and optional `Base URL: https://openrouter.ai/api/v1` (field `url` in the credential JSON). The `lmChatOpenAi` node then uses `model: inclusionai/ling-3.0-flash-fin:free` with `options: {}`. For direct OpenAI, leave Base URL empty and use `gpt-4o-mini` or `text-embedding-3-small`.

Embeddings: `text-embedding-3-small` produces 1536-dimensional vectors matching `pgvector vector(1536)`. If using OpenRouter embeddings, ensure dimensions match; otherwise `vector(3072)` is needed for `text-embedding-3-large`.

`N8N_ENCRYPTION_KEY` must be set in `.env` before the first `docker compose up -d` to persist credential encryption. Changing it later invalidates existing credentials.

## Webhook vs Polling Setup

**Webhook-native (when you have a public `https://` domain):**

- Set `.env` `WEBHOOK_URL=https://<domain>/` (or `N8N_WEBHOOK_URL` for newer n8n; both work, the former is deprecated in logs).
- `docker compose up -d`
- In n8n, activate `rag-doc-search/workflow.json` (`Telegram Trigger` 1.2) or a `Telegram Trigger` variant of `customer-support-agent/workflow.json`. n8n automatically calls `setWebhook https://<domain>/webhook/<uuid>`.
- Telegram requires HTTPS with a valid certificate; `http://localhost:5678` fails with `Bad Request: bad webhook: HTTPS url must be provided for webhook`.

**Polling via poller.py (localhost, CGNAT, no domain) - production path for `01-telegram-ai-bot.json`:**

- Keep `.env` `WEBHOOK_URL=http://localhost:5678/` and `docker compose up -d`.
- Activate `customer-support-agent/workflow.json` (`Webhook` `POST /webhook/telegram`, `responseMode: responseNode`).
- Clear any webhook before polling:

```bash
curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/deleteWebhook?drop_pending_updates=true"
# {"ok":true,"result":true,"description":"Webhook was deleted"}
# or "Webhook is already deleted" - both mean ready for getUpdates
```

- Start `poller.py`: `python3 -u poller.py` long-polls `GET getUpdates?offset=OFFSET&timeout=30` and `POST`s each raw `Update` to `http://localhost:5678/webhook/telegram`. `OFFSET` is never reset and is held in the poller process.

Community polling nodes (`@mentoster/n8n-nodes-telegram-polling` `0.1.3` with `telegramPollingTrigger` `timeout 60 limit 50 restrictChatIds`, and `n8n-nodes-telegram-getupdates-api` `1.4.1` with 21 update types) are alternatives but require `N8N_CUSTOM_EXTENSIONS=/home/node/.n8n/custom` and UI installation. `poller.py` works on stock n8n with no custom extensions and is the documented ready path.

## Poller Setup (Ready)

`poller.py` (36 lines) implements the `sxyrxyy/n8n-telegram-no-expose` pattern: external long polling forwarding to a local webhook.

```python
TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11")
WEBHOOK = "http://localhost:5678/webhook/telegram"
OFFSET = 0
# clear pending
r = requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates", params={"offset": 0})
if r.json().get("result"):
    OFFSET = max(u["update_id"] for u in r.json()["result"]) + 1
    requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates", params={"offset": OFFSET, "timeout": 1})
while True:
    r = requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates",
                     params={"offset": OFFSET, "timeout": 30}, timeout=35)
    for upd in r.json().get("result", []):
        OFFSET = max(OFFSET, upd["update_id"] + 1)
        requests.post(WEBHOOK, json=upd, timeout=10)
```

- Init: prints `Polling 123456:ABC... -> http://localhost:5678/webhook/telegram OFFSET <n>`. Clears pending by `GET offset=0` then `GET offset=OFFSET` to acknowledge `max(update_id)+1`.
- Loop: `GET getUpdates?offset=OFFSET&timeout=30` with HTTP timeout 35s (long polling). On each `Update`, `OFFSET = max(OFFSET, update_id+1)` immediately, then `POST /webhook/telegram` with the raw JSON. Logs `fwd <id> 'text' -> 200 {"ok":true}`.

Run:

```bash
nohup python3 -u poller.py > /tmp/poller.log 2>&1 &
ps aux | grep poller
cat /tmp/poller.log
# fwd 1003 'hello fixed' -> 200 {"ok":true}
curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?offset=0"
# pending 0 after ack
```

Execution verification: `curl "http://localhost:5678/rest/executions?limit=3"` shows `success` for each forwarded update. Manual test: `curl -X POST http://localhost:5678/webhook/telegram -H "Content-Type: application/json" -d '{"update_id":1,"message":{"chat":{"id":5785127604},"text":"hi"}}'` returns `{"ok":true}`. `GET /webhook/telegram` correctly returns 404.

Compose sidecar example (see `../README.md` for full snippet):

```yaml
telegram-poller:
  image: python:3.11-slim
  container_name: telegram-poller
  restart: unless-stopped
  network_mode: host
  depends_on: [n8n]
  environment:
    - TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
  volumes: ["./poller.py:/poller.py:ro"]
  command: ["python", "-u", "/poller.py"]
```

Only one poller per bot token. Two consumers cause `409 Conflict: terminated by other getUpdates request` and missed messages (conflict can also be between a poller and an active `setWebhook`).

Debug: `curl -X POST http://localhost:5678/webhook/debug` with an echo workflow shows the webhook output is wrapped in `body` (`bodyKeys: [update_id, message]`).

## Production Embedding

- **As a microservice:** Keep n8n as the LLM orchestrator. Your app does `POST http://localhost:5678/webhook/telegram` (or `/webhook/app`) with a JSON payload; n8n runs `AI Agent` and returns via `Respond to Webhook` JSON. No Telegram webhook is needed if your backend calls n8n directly.
- **As a sidecar:** Add a `telegram-poller` service to your existing `docker-compose.yml` (see `README.md` Quick Start section 5). n8n and the poller share `network_mode: host` or a common bridge with `postgres`.
- **Observability:** n8n exposes `GET /rest/executions?limit=10` with `status: success/error` per workflow. Check `docker logs n8n-demo --tail 50` and `n8nEventLog`. Add an error branch per `n8n-error-handling-official` (`Telegram` node `output(1)` / `main[1]` to `Slack` or `Email`) for AI failures.
- **Scaling:** One poller per bot token. For high throughput, replace `requests` with `httpx` async or `python-telegram-bot`, but keep `OFFSET` single-writer (immediate `max(update_id)+1` after each `Update`).
- **HTTPS production path:** When you have a domain, replace `poller.py` with the native `Telegram Trigger` by setting `WEBHOOK_URL=https://<domain>/`. Telegram `setWebhook` auto-registers on workflow activation; the same `AI Agent` / `Telegram Send` / `Window Buffer Memory` nodes work without code changes except for the trigger.

## RAG (PGVector / Qdrant)

- **Ingest:** `rag-doc-search/ingest.json` (`Read Binary Files -> Extract from File (pdf) -> Edit Fields -> PGVector Store` with `Default Data Loader -> PGVector`, `Embeddings -> PGVector`, `Text Splitter -> Loader`). Uses `chunkSize: 1000`, `chunkOverlap: 200`, `model: text-embedding-3-small`, `tableName: embeddings` `vector(1536)`. The table auto-creates; for manual creation see `rag-doc-search/README.md` SQL (`vector(1536)` for `text-embedding-3-small`, `vector(3072)` for `text-embedding-3-large`).
- **Query:** `rag-doc-search/workflow.json` (`Telegram Trigger -> AI Agent -> Telegram Send` with `toolVectorStore -> PGVector + embeddingsOpenAi + lmChatOpenAi`). Tool `limit: 4` for retrieval. The `AI Agent` must use the same embeddings model as ingestion; mismatched models return no matches. For a webhook/poller deployment, change the trigger to `Webhook` `POST /webhook/rag` and update `AI Agent.text` to `{{ $json.body.message.text }}` and `Telegram Send.chatId` to `{{ $('Webhook').item.json.body.message.chat.id }}`.
- **Qdrant:** Optional alternative vector store. To use Qdrant, replace the `PGVector Store` node with `Qdrant Vector Store` (`@n8n/n8n-nodes-langchain.vectorStoreQdrant` 1.1) using `collection: documents`, `distance: Cosine`, `vector size: 1536`. Set `QDRANT_URL` to `http://127.0.0.1:6333` for host network or `http://qdrant:6333` for bridge.
- **Models:** `gpt-4o-mini` and `inclusionai/ling-3.0-flash-fin:free` (via OpenRouter) are both supported for the chat model; `text-embedding-3-small` is required for the embeddings to match the `vector(1536)` column.

Workflow files validated: `python3 -m json.tool customer-support-agent/workflow.json`, `rag-doc-search/workflow.json`, `rag-doc-search/ingest.json`, `lead-scoring-crm/workflow.json` all pass.
