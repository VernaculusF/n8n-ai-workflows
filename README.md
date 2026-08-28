# n8n-ai-workflows

Ready-to-import n8n workflows for AI automation. Includes a Telegram support bot that runs without public HTTPS via a long-polling bridge, a PDF-to-pgvector ingestion pipeline, a Telegram RAG query workflow, and a universal site chatbot (any domain, one workflow). Ships with a Docker stack (n8n, postgres/pgvector, qdrant) and a production-ready Telegram poller.

## Contents

- [Overview](#overview)
- [Ready Config](#ready-config-verified-2026-08-27)
- [Workflows](#workflows)
  - [customer-support-agent](#customer-support-agent---telegram-ai-support-bot-production)
  - [rag-doc-search](#rag-doc-search---rag-over-pgvector-ingest--query)
  - [lead-scoring-crm](#lead-scoring-crm---webhook-ai-scoring-to-crm)
  - [universal-site-agent](#universal-site-agent---universal-site-chatbot-huge-38-nodes)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Credentials and Environment](#credentials-and-environment)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)
- [License](#license)

## Overview

This repository solves four common problems:

- **Telegram bot without public HTTPS.** Telegram `setWebhook` requires a public HTTPS URL. This project uses `poller.py` to long-poll `getUpdates` and forward updates to a local `Webhook` node, so you can run on `localhost`, behind CGNAT, or on IPv6-only hosts without `ngrok` or a domain.
- **Reliable delivery without duplicates.** A single long-polling consumer with `OFFSET = max(update_id) + 1` and `GET getUpdates?offset=OFFSET&timeout=30` avoids overlapping executions and `workflowStaticData` races that cause duplicate replies.
- **Private-document RAG.** Ingest PDFs once into pgvector or qdrant, then answer Telegram questions strictly from retrieved context via a Vector Store Tool.
- **Universal site chat without per-site forks.** One `POST /webhook/site-chat` workflow (`universal-site-agent`) serves any domain via `Code: Config & Normalize` (`$env.SITE_URL` fallback), RAG over `site_embeddings`, and intent routing to Slack/Telegram/Postgres/Sheets.

All workflows validate with `python3 -m json.tool` and use `@n8n/n8n-nodes-langchain.*` types where required.

## Ready Config (verified 2026-08-27)

- **n8n** `2.36.7` (`docker.n8n.io/n8nio/n8n`), `network_mode: host`, `N8N_COMMUNITY_PACKAGES_ENABLED=true`, `N8N_CUSTOM_EXTENSIONS=/home/node/.n8n/custom`, `WEBHOOK_URL=http://localhost:5678/`, `GENERIC_TIMEZONE=Europe/Moscow`
- **Postgres** `pgvector/pgvector:pg16`, container `n8n-pgvector`, `5433:5432`, healthcheck `pg_isready`, database `n8n`, user `n8n`
- **Qdrant** `qdrant/qdrant:latest`, `6333:6333`, `6334:6334`, optional vector store alternative
- **Workflows** `customer-support-agent/workflow.json` (Webhook + AI Agent + Memory), `rag-doc-search/workflow.json` + `ingest.json` (Manual + PGVector + RAG), `lead-scoring-crm/workflow.json` (Webhook + AI Scoring + Sheets/Slack), `universal-site-agent/workflow.json` + `ingest.json` + `widget.html` + `sql/init.sql` (Universal Site Chat, 38 nodes, RAG + intent routing)
- **Poller** `poller.py` (36 lines, `requests`, long polling, `OFFSET` persisted in process, `python3 -u` unbuffered)
- **Credentials** `telegramApi` id `1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d`, `openAiApi` id `2a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5e`, `postgres` (host `127.0.0.1` for host network, `postgres` for bridge, port `5433`)
- **Model** `inclusionai/ling-3.0-flash-fin:free` via OpenRouter `https://openrouter.ai/api/v1` (verified cost 0, also works with `gpt-4o-mini` on OpenAI direct)

## Workflows

### customer-support-agent - Telegram AI Support Bot (production)

`customer-support-agent/workflow.json` `preview.png` `README.md` — see [customer-support-agent/README.md](customer-support-agent/README.md)

**Trigger:** `Webhook` (`n8n-nodes-base.webhook` 2) - `POST /webhook/telegram`, `responseMode: responseNode`, `webhookId: a85e705e-a79f-47f4-b183-121603f310`. Expects raw Telegram `Update` JSON forwarded by `poller.py`.

**Nodes:**

- `Webhook` 2 - `POST /webhook/telegram`, `responseMode: responseNode`. Output shape is `{ body: { update_id, message: { chat, text, caption } }, headers, query, params }`.
- `AI Agent` (`@n8n/n8n-nodes-langchain.agent` 1.8) - `promptType: define`, `text: ={{ $json.body.message.text || $json.body.message.caption || '' }}`, `systemMessage: "You are helpful support assistant. Answer concisely in Russian. One reply per message."`
- `OpenAI Chat Model` (`@n8n/n8n-nodes-langchain.lmChatOpenAi` 1.2) - `model: inclusionai/ling-3.0-flash-fin:free` via OpenRouter `https://openrouter.ai/api/v1`, credential `openAiApi` id `2a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5e`, connected as `ai_languageModel` to AI Agent.
- `Window Buffer Memory` (`@n8n/n8n-nodes-langchain.memoryBufferWindow` 1.3) - `sessionKey: ={{ $('Webhook').item.json.body.message.chat.id }}`, `sessionIdType: customKey`, `contextWindowLength: 10`, connected as `ai_memory` to AI Agent. Provides per-chat isolated 10-message history.
- `Telegram Send` (`n8n-nodes-base.telegram` 1.2) - `chatId: ={{ $('Webhook').item.json.body.message.chat.id }}`, `text: ={{ $json.output }}`, `appendAttribution: false`, credential `telegramApi` id `1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d`.
- `Respond to Webhook` (`n8n-nodes-base.respondToWebhook` 1.1) - `respondWith: json`, `responseBody: {"ok": true}`.

**Flow:**

```
poller.py  GET getUpdates?offset=OFFSET&timeout=30
    |
    v  POST http://localhost:5678/webhook/telegram  { update_id, message }
Webhook (POST /webhook/telegram)
    |
    v  $json.body.message.text
AI Agent  <-- ai_languageModel: OpenAI Chat Model (ling-3.0-flash-fin:free)
          <-- ai_memory: Window Buffer Memory (sessionKey = chat.id, window 10)
    |
    v  $json.output
Telegram Send (chatId = $('Webhook').item.json.body.message.chat.id)
    |
    v
Respond to Webhook  {"ok": true}
```

Connections: `Webhook -> AI Agent -> Telegram Send -> Respond` (main), `OpenAI Chat Model -> AI Agent` (ai_languageModel), `Window Buffer Memory -> AI Agent` (ai_memory).

**Purpose:** Production Telegram support bot for any `message` update. Handles `text` and `caption`, maintains per-chat memory, replies once per inbound message, and acknowledges the webhook with `{"ok": true}`. Pair with `poller.py` for localhost development without HTTPS.

**Where to use:**

- Customer support bot in Telegram DM or group - customize `systemMessage` with FAQ, return policy, or product knowledge; add `IF` or `Code` guards for intents if needed.
- Backend for a web app, Slack, or Discord - keep n8n as the LLM orchestrator and call `POST /webhook/telegram` from your backend; replace `Telegram Send` with `Respond to Webhook` JSON when no Telegram reply is needed.
- Channel digest or notification assistant - reuse the same `AI Agent` + `Memory` pattern with a `Schedule` or `RSS` trigger to summarize content before sending via `Telegram Send`.

**Showcase:** [showcase proof](customer-support-agent/showcase/README.md)

### rag-doc-search - RAG over PGVector (ingest + query)

`rag-doc-search/workflow.json` + `ingest.json` `preview.png` `README.md` — see [rag-doc-search/README.md](rag-doc-search/README.md)

#### Ingest `ingest.json` - PDF Ingest to PGVector

**Trigger:** `Manual Trigger` (`n8n-nodes-base.manualTrigger` 1) - run on demand for each ingest batch.

**Nodes:**

- `Manual Trigger` 1
- `Read Binary Files` (`n8n-nodes-base.readBinaryFiles` 1) - `fileSelector: =/data/pdfs/*.pdf` (mount host directory or copy PDFs into container at `/data/pdfs`).
- `Extract from File` (`n8n-nodes-base.extractFromFile` 1) - `operation: pdf`, `binaryPropertyName: data`.
- `Edit Fields` (`n8n-nodes-base.set` 3.4) - maps `text: ={{ $json.text }}` for the document loader.
- `Postgres PGVector Store` (`@n8n/n8n-nodes-langchain.vectorStorePGVector` 1.3) - `mode: insert`, `tableName: embeddings`, credential `postgres`.
- `Default Data Loader` (`@n8n/n8n-nodes-langchain.documentDefaultDataLoader` 1) - `jsonMode: expressionData`, `jsonData: ={{ $json.text }}`, metadata `source: ={{ $binary.data.fileName || $json.fileName || 'pdf' }}`, connected as `ai_document` to PGVector Store.
- `Recursive Character Text Splitter` (`@n8n/n8n-nodes-langchain.textSplitterRecursiveCharacterTextSplitter` 1) - `chunkSize: 1000`, `chunkOverlap: 200`, connected as `ai_textSplitter` to Default Data Loader.
- `Embeddings OpenAI` (`@n8n/n8n-nodes-langchain.embeddingsOpenAi` 1.2) - `model: text-embedding-3-small` (1536 dims), credential `openAiApi`, connected as `ai_embedding` to PGVector Store.

**Flow:**

```
Manual Trigger
    |
    v
Read Binary Files (/data/pdfs/*.pdf)
    |
    v
Extract from File (pdf, binaryPropertyName: data)
    |
    v
Edit Fields (text = $json.text)
    |
    v
Postgres PGVector Store (insert, table: embeddings)
    ^  ai_document: Default Data Loader (text, metadata source)
    |      ^  ai_textSplitter: Recursive Character Text Splitter (1000/200)
    ^  ai_embedding: Embeddings OpenAI (text-embedding-3-small)
```

**Purpose:** One-shot ingestion pipeline that reads local PDFs, extracts text, chunks it, embeds with `text-embedding-3-small`, and inserts into the `embeddings` table (`vector(1536)`). Table auto-creates on first insert; see `rag-doc-search/README.md` for the manual SQL.

**Where to use:**

- Internal docs RAG - index policy documents, handbooks, or contracts once, then query via `03-telegram-rag-query.json` or a webhook variant.
- Knowledge base for a support bot - combine with `01-telegram-ai-bot.json` by adding a Vector Store Tool to the agent so answers are grounded in ingested PDFs.
- Batch re-index on doc updates - rerun the Manual Trigger after mounting new PDFs; replace PGVector Store with `Qdrant Vector Store` (`collection: documents`, `distance: Cosine`) if using qdrant.

#### Query `workflow.json` - Telegram RAG Query (PGVector)

**Trigger:** `Telegram Trigger` (`n8n-nodes-base.telegramTrigger` 1.2) - `updates: [message]`, `webhookId: d26b0a99-ecf2-4c9f-8e1a-f00183858f2c`, credential `telegramApi`. For localhost without HTTPS, replace with `Webhook` `POST /webhook/rag` and `poller.py` as in `01-telegram-ai-bot.json`.

**Nodes:**

- `Telegram Trigger` 1.2 - webhook-native trigger; for poller mode use `Webhook` and change `AI Agent.text` to `{{ $json.body.message.text }}` and `Telegram Send.chatId` to `{{ $('Webhook').item.json.body.message.chat.id }}`.
- `AI Agent` (`@n8n/n8n-nodes-langchain.agent` 2) - `text: ={{ $json.message.text }}` (webhook variant: `{{ $json.body.message.text }}`), `systemMessage: "You are helpful support assistant. Use the vector store tool to answer questions from the knowledge base. If the answer is not in the tool output, say you do not have information. Cite sources when possible."`
- `OpenAI Chat Model` (`@n8n/n8n-nodes-langchain.lmChatOpenAi` 1.2) - `model: gpt-4o-mini` (or `ling-3.0-flash-fin:free` via OpenRouter), connected as `ai_languageModel` to AI Agent.
- `Window Buffer Memory` (`@n8n/n8n-nodes-langchain.memoryBufferWindow` 1.3) - `sessionKey: ={{ $json.message.chat.id }}` (webhook variant: `{{ $('Webhook').item.json.body.message.chat.id }}`), `sessionIdType: customKey`, `contextWindowLength: 10`, connected as `ai_memory`.
- `Vector Store Tool` (`@n8n/n8n-nodes-langchain.toolVectorStore` 1.1) - `description: "Search knowledge base for relevant documents to answer user questions. Use for any question about indexed PDFs."`, `topK: 4`, connected as `ai_tool` to AI Agent.
- `Postgres PGVector Store` (`@n8n/n8n-nodes-langchain.vectorStorePGVector` 1.3) - `tableName: embeddings`, connected as `ai_vectorStore` to Vector Store Tool.
- `Embeddings OpenAI` (`@n8n/n8n-nodes-langchain.embeddingsOpenAi` 1.2) - `model: text-embedding-3-small`, must match ingestion, connected as `ai_embedding` to PGVector Store.
- `OpenAI Chat Model for Tool` (`@n8n/n8n-nodes-langchain.lmChatOpenAi` 1.2) - `model: gpt-4o-mini`, connected as `ai_languageModel` to Vector Store Tool.
- `Telegram Send` (`n8n-nodes-base.telegram` 1.2) - `chatId: ={{ $('Telegram Trigger').item.json.message.chat.id }}`, `text: ={{ $json.output }}` (webhook variant: `{{ $('Webhook').item.json.body.message.chat.id }}`).

**Flow:**

```
Telegram Trigger (message)
    |
    v  $json.message.text
AI Agent  <-- ai_languageModel: OpenAI Chat Model
          <-- ai_memory: Window Buffer Memory (sessionKey = chat.id, window 10)
          <-- ai_tool: Vector Store Tool (topK 4)
                      ^  ai_vectorStore: Postgres PGVector Store (embeddings)
                      |       ^  ai_embedding: Embeddings OpenAI (text-embedding-3-small)
                      ^  ai_languageModel: OpenAI Chat Model for Tool
    |
    v  $json.output
Telegram Send
```

Connections: `Telegram Trigger -> AI Agent -> Telegram Send` (main), plus `OpenAI Chat Model -> Agent` (ai_languageModel), `Window Buffer Memory -> Agent` (ai_memory), `Vector Store Tool -> Agent` (ai_tool), `Postgres PGVector Store -> Vector Store Tool` (ai_vectorStore), `Embeddings OpenAI -> PGVector` (ai_embedding), `OpenAI Chat Model for Tool -> Vector Store Tool` (ai_languageModel).

**Purpose:** Answers Telegram questions strictly from the pgvector knowledge base built by `02-pdf-ingest.json`. Retrieves up to 4 chunks per query and instructs the agent to cite sources and refuse when no context matches. Requires the same embeddings model for ingest and query.

**Where to use:**

- Internal knowledge assistant - answer "What does policy X say?" from indexed PDFs with source citations and no hallucination outside the store.
- Support bot with grounded answers - adapt the Webhook variant (`POST /webhook/rag`) so a web app or Slack bot can query the same vector store via `POST /webhook/rag`.
- Qdrant alternative - replace `Postgres PGVector Store` with `Qdrant Vector Store` (`collection: documents`, `vector size: 1536`, `distance: Cosine`) when using qdrant.

**Showcase:** [showcase proof](rag-doc-search/showcase/README.md)

### lead-scoring-crm - Webhook AI Scoring to CRM

`lead-scoring-crm/workflow.json` `preview.png` `README.md` — see [lead-scoring-crm/README.md](lead-scoring-crm/README.md)

**Trigger:** `Webhook` (`n8n-nodes-base.webhook` 2) - `POST /webhook/lead`, `webhookId c2d3e4f5-a6b7-48c9-9d0e-1f2a3b4c5d6e`, `responseMode: responseNode`. Accepts `{ name, email, company, message, phone, source }`.

**Nodes:** `Webhook 2` → `AI Agent 1.8` (`text={{JSON.stringify($json.body)}}`, system: return `{"score","tier","reason","next_step"}`) + `OpenAI Chat Model 1.2` (`ling-3.0-flash-fin:free`) → `Code 2 Parse Score` → `IF 2 score≥70` → `Slack 1.3 #leads` (hot only) → `Google Sheets 4.4` append `Leads` → `Respond 1.1` `{ok,score,tier}`

**Flow:** `POST /webhook/lead → AI Agent --lm OpenAI → Parse Score → IF Hot → Slack → Sheets → Respond` (`false` skips Slack)

**Purpose:** Webhook AI lead scoring; stateless, threshold branching, Sheets CRM.

**Where to use:** Landing form scoring, Telegram lead qualification, enrichment pipeline.

**Showcase:** [showcase proof](lead-scoring-crm/showcase/README.md)

### universal-site-agent - Universal Site Chatbot (HUGE, 38 nodes)

`universal-site-agent/workflow.json` + `ingest.json` + `widget.html` + `sql/init.sql` `preview.png` `README.md` — see [universal-site-agent/README.md](universal-site-agent/README.md)

**Trigger:** `Webhook` (`n8n-nodes-base.webhook` 2) - `POST /webhook/site-chat`, `responseMode: responseNode`, `webhookId: universal-site-agent`. Accepts `{message, sessionId, siteUrl, siteName, brandVoice}`; `Code: Config & Normalize` falls back to `$env.SITE_URL/SITE_NAME/BRAND_VOICE` for any domain.

**Nodes (38):** `Webhook Site Chat` → `Code: Config & Normalize` → `Postgres Rate Limit Check` → `IF Rate Limited` → `Respond 429` / `Code Guardrails` → `IF Guardrails Blocked` → `Respond 403` / `Postgres Load History` → `Code Build History` → `AI Agent` (`text={{sanitizedMessage}}`, system `siteName/brandVoice + JSON {answer,confidence,intent,language,needs_handoff,lead,ticket}`) + `OpenAI Chat Model` (`ling-3.0-flash-fin:free` via OpenRouter) + `Window Buffer Memory` (`sessionKey=sessionId, 20`) + 5 `ai_tool` (`Vector Store Tool` topK5 → `PGVector site_embeddings` + `Embeddings text-embedding-3-small`, `Postgres Writer Tool`, `HTTP Site API Tool`, `Calculator`, `Code Sanitize`) → `IF KB Hit` → `HTTP DuckDuckGo` → `Code Rerank` → `Code Parse Output` → `Switch Intent` (`answer/lead/ticket/handoff`) → `IF Handoff Required` → `Slack #support` + `Telegram admin` + `Postgres Insert Chat History/Lead/Ticket` + `HTTP Site API Write POST {{siteUrl}}/api/crm/lead continueOnFail` + `Google Sheets Analytics` → `Merge Handoff Results` → `Code Format Final Response` → `Respond Success 200` plus `IF Lead Exists`, `IF Ticket Needed` branches.

**Flow:**

```
POST /webhook/site-chat {message, sessionId, siteUrl}
  -> Code Config -> Postgres Rate Limit IF >=10/min -> 429
               -> Code Guardrails IF blocked -> 403
               -> Postgres Load History -> Code Build History -> Window Buffer Memory (20)
               -> AI Agent (sanitizedMessage, siteName/brandVoice JSON) --LM OpenRouter --Memory --5 Tools (VectorStore topK5 + PGVector/Embeddings, PGWriter, SiteAPI, Calc, Sanitize)
               -> IF KB Hit --fallback DuckDuckGo -> Rerank
               -> Parse Output -> Switch Intent (answer/lead/ticket/handoff)
                    answer -> IF Handoff -> Postgres Chat History
                    lead   -> IF Lead Exists -> Postgres Lead -> HTTP Site API Write
                    ticket -> IF Ticket Needed -> Postgres Ticket -> Google Sheets
                    handoff-> Slack + Telegram -> Postgres inserts -> Merge
               -> Code Format Final -> Respond 200 {ok,answer,formatted,confidence,intent}
```

Connections: main linear as above, `ai_languageModel: OpenAI Chat Model -> AI Agent`, `ai_memory: Window Buffer Memory -> AI Agent`, `ai_tool: 5 tools -> AI Agent`, `ai_vectorStore: PGVector -> Vector Store Tool`, `ai_embedding: Embeddings -> PGVector`.

**Purpose:** Universal site chatbot for any domain without forks: RAG over `site_embeddings` (ingest sitemap + `/data/site_kb/*.{pdf,md,txt}` via `ingest.json`), guardrailed, rate-limited, intent-routed CRM (leads/tickets/handoff) to Postgres/Sheets/Slack/Telegram/Site API. Embed `widget.html` (`window.SITE_CHAT_CONFIG`, `localStorage sessionId`, `POST /webhook/site-chat`, markdown-lite).

**Where to use:**

- Any marketing/docs/saas/shop site - one workflow for all domains via `$env.SITE_URL`
- Embed widget or call webhook from your backend (Next.js, Django) with `sessionId=user.id`
- Replace Slack/Telegram with your helpdesk; `HTTP Site API Write` posts to `{{siteUrl}}/api/crm/lead`

**Showcase:** [showcase proof](universal-site-agent/showcase/README.md)

## Architecture

```
Telegram Bot API
    |
    |  GET https://api.telegram.org/bot<TOKEN>/getUpdates?offset=OFFSET&timeout=30
    |  (long polling, single consumer, OFFSET = max(update_id)+1)
    v
poller.py  (requests, OFFSET persisted in process)
    |
    |  POST http://localhost:5678/webhook/telegram  { update_id, message: { chat, text } }
    v
n8n Webhook (POST /webhook/telegram | POST /webhook/site-chat, responseMode: responseNode)
    |  $json = { body: { update_id, message } | { message, sessionId, siteUrl } , headers, query, params }
    v
Code Guardrails / Rate Limit (universal-site-agent only) --IF blocked--> Respond 403/429
    |
    v
AI Agent (agent 1.8, text = $json.body.message.text | sanitizedMessage, systemMessage)
    |  ai_languageModel -> lmChatOpenAi (1.2, inclusionai/ling-3.0-flash-fin:free via OpenRouter https://openrouter.ai/api/v1)
    |  ai_memory        -> Window Buffer Memory (1.3, customKey sessionKey = $('Webhook').item.json.body.message.chat.id | $('Code: Config').item.json.sessionId, window 10/20)
    |  ai_tool (rag/universal)-> toolVectorStore -> PGVector site_embeddings/embeddings + embeddingsOpenAi (text-embedding-3-small) + Calculator/Sanitize/PGWriter/SiteAPI
    |  knowledge fallback (universal): HTTP DuckDuckGo -> Code Rerank
    v  $json.output / $json.answer
Telegram Send (1.2, chatId = $('Webhook').item.json.body.message.chat.id)  OR  Slack/Telegram + Postgres/HTTP/Sheets (universal: Switch Intent -> Insert Lead/Ticket/ChatHistory -> Merge -> Format -> Respond 200)
    |
    v
Respond to Webhook (1.1, {"ok": true} | {ok, answer, formatted, confidence, intent})
```

`universal-site-agent` adds: `widget.html` (`window.SITE_CHAT_CONFIG`, `localStorage sessionId`, `POST /webhook/site-chat`) → `Code: Config & Normalize` (`$env.SITE_URL` fallback) → `Postgres Rate Limit`/`Guardrails` → `Postgres Load History`/`Code Build History`/`Window Buffer Memory 20` → `AI Agent` JSON {answer,confidence,intent,language,needs_handoff,lead,ticket} → `IF KB Hit`→`DuckDuckGo`→`Rerank`→`Parse Output`→`Switch Intent`→`Slack/Telegram/Postgres/HTTP Site API Write continueOnFail/Sheets`→`Merge`→`Format`→`Respond 200`. Ingest via `ingest.json` (Manual + Read Binary `/data/site_kb/*.{pdf,md,txt}` + Extract + HTTP Sitemap + Code Parse URLs + HTTP Fetch + HTML Extract + Edit Fields + PGVector `site_embeddings` + Default Loader + Splitter 1000/200 + Embeddings).

`docker-compose.yml` uses `network_mode: host` so `n8n` can reach `api.telegram.org` (`149.154.166.110:443`) and `poller.py` can reach `localhost:5678` without bridge isolation. `postgres` healthcheck (`pg_isready`) gates `n8n` startup. Named volumes: `n8n_data`, `pgdata`, `qdrant_storage`.

Why not pure webhook: Telegram `setWebhook` requires `https://` with a valid certificate; `http://localhost:5678` is rejected with `Bad Request: bad webhook: HTTPS url must be provided for webhook`. Use `poller.py` for localhost, or set `WEBHOOK_URL=https://<domain>/` and use `Telegram Trigger` when you have a domain.

Why not Schedule polling inside n8n: an internal `Schedule -> HTTP getUpdates -> Code` loop spawns overlapping executions and `workflowStaticData` flushes only after success, so `offset=0` is re-sent and the same `update_id` is processed multiple times. The external `poller.py` keeps a single process and updates `OFFSET` immediately.

## Quick Start

### 1. Configure environment

```bash
cp .env.example .env
# edit TELEGRAM_BOT_TOKEN (from @BotFather) and OPENAI_API_KEY (OpenRouter or OpenAI)
# For OpenRouter: OPENAI_API_KEY=sk-or-v1-... and set n8n OpenAI credential Base URL to https://openrouter.ai/api/v1
# For host network (default): POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5433 QDRANT_URL=http://127.0.0.1:6333
```

### 2. Start the stack

```bash
docker compose up -d
# n8n: http://localhost:5678 (create owner account on first open)
# postgres: localhost:5433
# qdrant: http://localhost:6333/dashboard
```

### 3. Create credentials in n8n UI

Open `http://localhost:5678` and go to `Credentials`:

- `Telegram API` - `accessToken` from @BotFather.
- `OpenAI API` - `apiKey`; if using OpenRouter set Base URL to `https://openrouter.ai/api/v1`.
- `Postgres` - `host: 127.0.0.1` (or `postgres` for bridge), `database: n8n`, `user: n8n`, `password: n8n_password`, `port: 5433`.

### 4. Import workflows

UI: `Workflows -> Import from File -> select customer-support-agent/workflow.json` (and `rag-doc-search/workflow.json`, `lead-scoring-crm/workflow.json` as needed). Assign credentials after import and activate.

CLI (container must be running):

```bash
docker cp customer-support-agent/workflow.json n8n-demo:/tmp/w.json
docker exec n8n-demo n8n import:workflow --input=/tmp/w.json
# then in UI assign credentials and activate, or use the n8n API to activate
```

### 5. Start the Telegram poller (no public HTTPS required)

```bash
# ensure no webhook is set; required before getUpdates
curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/deleteWebhook?drop_pending_updates=true"

# pending messages are cleared on poller start (max update_id + 1)
python3 -u poller.py > /tmp/poller.log 2>&1 &
cat /tmp/poller.log
# fwd 1003 'hello fixed' -> 200 {"ok":true}

# manual webhook test (no Telegram needed)
curl -X POST http://localhost:5678/webhook/telegram -H "Content-Type: application/json" \
  -d '{"update_id":1,"message":{"message_id":1,"chat":{"id":YOUR_CHAT_ID},"text":"hello"}}'
# -> {"ok": true}
```

As a compose sidecar:

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

Only one poller per bot token. Send a message to your bot in Telegram and you should get a single AI reply.

### 6. Ingest PDFs (optional, for RAG)

Put PDFs into `./data/pdfs` or mount into the container, then in n8n execute `02-pdf-ingest.json` via `Manual Trigger`. The `embeddings` table auto-creates; for `text-embedding-3-small` it is `vector(1536)`, for `text-embedding-3-large` it is `vector(3072)`.

## Credentials and Environment

Copy `.env.example` to `.env` and fill in values:

| Variable | Example | Purpose |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | `123456:ABC-DEF...` | Bot token from @BotFather; used by `poller.py` and n8n `telegramApi` credential |
| `OPENAI_API_KEY` | `sk-or-v1-...` or `sk-proj-...` | OpenRouter or OpenAI key for `openAiApi` credential |
| `POSTGRES_DB` | `n8n` | Postgres database name |
| `POSTGRES_USER` | `n8n` | Postgres user |
| `POSTGRES_PASSWORD` | `n8n_password` | Postgres password |
| `POSTGRES_HOST` | `127.0.0.1` | `127.0.0.1` for host network, `postgres` for bridge |
| `POSTGRES_PORT` | `5433` | `5433` for host network, `5432` for bridge |
| `DATABASE_URL` | `postgresql://n8n:...@127.0.0.1:5433/n8n` | Alternative explicit URL for tools expecting `DATABASE_URL` |
| `QDRANT_URL` | `http://127.0.0.1:6333` | Qdrant URL; `http://qdrant:6333` for bridge |
| `QDRANT_API_KEY` | `` | Optional Qdrant API key |
| `WEBHOOK_URL` | `http://localhost:5678/` | `http://localhost:5678/` for poller mode, `https://<domain>/` for webhook mode |
| `N8N_HOST` | `localhost` | n8n host |
| `N8N_PORT` | `5678` | n8n port |
| `GENERIC_TIMEZONE` | `Europe/Moscow` | n8n timezone |
| `N8N_ENCRYPTION_KEY` | `replace-with-random-32-char-string` | Must be set before first `docker compose up -d`; changing it invalidates existing credentials |

n8n credentials (UI `Credentials`):

- `telegramApi` (`accessToken`) - used by `Telegram Send` and `Telegram Trigger` / `Webhook` chain. One credential per bot token.
- `openAiApi` (`apiKey` + optional Base URL `https://openrouter.ai/api/v1`) - used by `lmChatOpenAi` (`inclusionai/ling-3.0-flash-fin:free`, `gpt-4o-mini`, etc.) and `embeddingsOpenAi` (`text-embedding-3-small`). The model list for OpenRouter is at `https://openrouter.ai/api/v1/models`.
- `postgres` (`host`, `port`, `database`, `user`, `password`) - used by `vectorStorePGVector`. For host network the host is `127.0.0.1`, not `postgres`.

Notes:

- `WEBHOOK_URL` vs `N8N_WEBHOOK_URL`: newer n8n logs deprecate `WEBHOOK_URL` in favor of `N8N_WEBHOOK_URL`; both work for now.
- `deleteWebhook` (required before polling): `curl "https://api.telegram.org/bot<TOKEN>/deleteWebhook?drop_pending_updates=true"` returns `{"ok":true}` when ready for `getUpdates`.
- Poller uses `GET https://api.telegram.org/bot<TOKEN>/getUpdates?offset=OFFSET&timeout=30` with HTTP timeout 35s, then `POST http://localhost:5678/webhook/telegram` with the raw `Update` JSON.

## Troubleshooting

- **`Bad Request: bad webhook: HTTPS url must be provided for webhook`** - You activated `Telegram Trigger` with `WEBHOOK_URL=http://localhost:5678`. Telegram requires HTTPS for webhooks. Use `poller.py` + `Webhook` workflow `01-telegram-ai-bot.json` for localhost, or set `WEBHOOK_URL=https://<public-domain>` and use `Telegram Trigger` when you have a domain.

- **`No prompt specified` (AI Agent)** - `Webhook` output is wrapped in `body` (`{ body, headers, query, params }`). `{{ $json.message.text }}` is empty at the Agent. Fix `AI Agent.text` to `={{ $json.body.message.text || $json.body.message.caption || '' }}`.

- **`chat_id is empty` or `Bad Request: chat not found` (Telegram Send 400)** - After `AI Agent`, `$json` is `{ output }`, not the webhook body. `{{ $json.body.message.chat.id }}` and `{{ $json.message.chat.id }}` are empty at that point. Fix `chatId` to `={{ $('Webhook').item.json.body.message.chat.id }}`.

- **`Error in sub-node Window Buffer Memory`** - `memoryBufferWindow` needs a per-chat `sessionKey`. If `sessionKey` is `{{ $json.body.message.chat.id }}` after the Agent, it is empty (same reason as above). Use `={{ $('Webhook').item.json.body.message.chat.id }}` with `sessionIdType: customKey` and `contextWindowLength: 10`, or remove the memory node for stateless behavior.

- **`ECONNREFUSED 149.154.166.110:443` inside container** - Telegram egress is blocked in bridge network (`docker exec n8n-demo wget -qO- https://api.telegram.org` fails in bridge but `curl` from host succeeds). Fix `docker-compose.yml` to `network_mode: host`, `POSTGRES_HOST=127.0.0.1`, `QDRANT_URL=http://127.0.0.1:6333`, `DB_POSTGRESDB_HOST=127.0.0.1`.

- **Spam 3-4 replies per message** - Caused by overlapping `Schedule` polling inside n8n and delayed `workflowStaticData` flush, so `offset=0` is re-sent. Check `GET getUpdates?offset=0` returns 0 pending after poll. Fix: use single `poller.py` long polling with `OFFSET = max(update_id)+1` immediately and no `Schedule` node in n8n.

- **`409 Conflict: terminated by other getUpdates request`** - Two pollers or a `setWebhook` is active for the same token. Run `curl "https://api.telegram.org/bot<TOKEN>/deleteWebhook?drop_pending_updates=true"` and ensure only one `poller.py` process per token (`ps aux | grep poller`).

- **Executions show `error` after manual `curl POST /webhook/telegram`** - Workflow path is `telegram` (`POST /webhook/telegram`), not `/webhook/debug`. `Respond to Webhook` must exist and be connected as `Webhook -> AI Agent -> Telegram Send -> Respond`. `GET /webhook/telegram` correctly returns 404; only `POST` is handled.

- **`Unrecognized node type: @mentoster/...telegramPollingTrigger`** - Community polling node not loaded. Requires `N8N_CUSTOM_EXTENSIONS=/home/node/.n8n/custom` + `npm install --prefix /home/node/.n8n/custom @mentoster/n8n-nodes-telegram-polling` + restart. Prefer `poller.py` to avoid custom nodes.

## Project Structure

```
.
├── docker-compose.yml              # n8n + postgres/pgvector + qdrant (host network)
├── .env.example                    # TELEGRAM_BOT_TOKEN, OPENAI_API_KEY, POSTGRES_*, QDRANT_URL, WEBHOOK_URL, SITE_URL
├── poller.py                       # Telegram long polling -> POST /webhook/telegram bridge (GET getUpdates?offset=OFFSET&timeout=30)
├── customer-support-agent/
│   ├── workflow.json               # Webhook -> AI Agent + Window Buffer Memory (per chat, 10) -> Telegram Send -> Respond
│   ├── preview.png                 # graph preview (3756x1956 dark)
│   ├── README.md                   # case, triggers, variables
│   └── showcase/                   # execution.png, telegram-chat.png, poller-log.png + README.md
├── rag-doc-search/
│   ├── workflow.json               # Telegram RAG Query (Vector Store Tool -> PGVector)
│   ├── ingest.json                 # Manual -> Read Binary -> Extract PDF -> PGVector (insert)
│   ├── preview.png                 # graph preview (3756x1956 dark)
│   ├── README.md                   # case, triggers, variables
│   └── showcase/                   # ingest-execution.png, query-execution.png, pgvector-proof.png + README.md
├── lead-scoring-crm/
│   ├── workflow.json               # Webhook -> AI Agent scoring -> IF -> Slack/Sheets -> Respond
│   ├── preview.png                 # graph preview (3756x1956 dark)
│   ├── README.md                   # case, triggers, variables
│   └── showcase/                   # webhook-curl.png, ai-scoring.png, sheets-proof.png + README.md
├── universal-site-agent/
│   ├── workflow.json               # HUGE 38 nodes: Webhook /webhook/site-chat -> Config -> RateLimit/Guardrails -> History -> Agent + 5 Tools -> KBHit/DuckDuckGo/Rerank -> Parse -> Switch -> Slack/Telegram/Postgres/HTTP/Sheets -> Merge -> Format -> Respond 200
│   ├── ingest.json                 # Manual -> Read Binary /data/site_kb/*.{pdf,md,txt} -> Extract -> HTTP Sitemap -> Code Parse URLs -> HTTP Fetch -> HTML Extract -> Edit Fields -> PGVector site_embeddings (1000/200) + Embeddings
│   ├── widget.html                 # vanilla JS floating chat widget (localStorage sessionId, POST /webhook/site-chat, markdown-lite, window.SITE_CHAT_CONFIG)
│   ├── sql/init.sql                # DB schema: site_embeddings vector(1536) ivfflat/hnsw, chat_history, leads, tickets + indexes
│   ├── preview.png                 # graph preview (3756x1956 dark)
│   ├── README.md                   # case, triggers, nodes table, flow, credentials, env, quick start, gotchas
│   └── showcase/                   # widget-demo.png, site-chat-execution.png, handoff-proof.png, db-widget-proof.png + README.md
├── docs/
│   └── CONFIG.md                   # extended integration guide (host vs bridge, OpenRouter, poller, RAG, universal site)
└── README.md
```

## License

MIT - see [LICENSE](LICENSE).
