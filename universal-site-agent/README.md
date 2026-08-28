# universal-site-agent
Universal site chatbot template: single Webhook for any website, RAG over `site_embeddings`, AI Agent with 5 tools, rate-limit & guardrails, intent routing (answer/lead/ticket/handoff) to Slack/Telegram/Postgres/Sheets. Ships with ingest pipeline for sitemap + `/data/site_kb`.

## Overview

This template solves universal site chat without per-site forks:

- **One webhook for any site.** `POST /webhook/site-chat` accepts `{message, sessionId, siteUrl, siteName}`. `Code: Config & Normalize` falls back to `$env.SITE_URL / SITE_NAME / BRAND_VOICE` so the same workflow runs for `example.com`, `shop.acme.io`, or `localhost` without redeploy.
- **Grounded answers.** Vector Store Tool (topK 5, `site_embeddings` `vector(1536)` via `text-embedding-3-small`) is the primary source. On miss, `HTTP DuckDuckGo` fallback + `Code Rerank` supplies web context before the Agent answers. Never hallucinate outside retrieved chunks.
- **Production guards.** Postgres rate limit (`>=10/min` → `429`), injection filter (`Code Guardrails` → `403`), `Code Sanitize` tool, and `needs_handoff` JSON contract prevent abuse and ensure escalation.
- **CRM-ready routing.** `Code Parse Output` extracts `{answer,confidence,intent,language,needs_handoff,lead,ticket}`. `Switch Intent` fans out to `answer` (direct), `lead`/`ticket` (Postgres `leads`/`tickets` + Site API `POST {{siteUrl}}/api/crm/lead`), `handoff` (Slack `#support` + Telegram admin + all inserts + Sheets `Analytics`).

All workflows validate with `python3 -m json.tool` and use `@n8n/n8n-nodes-langchain.*` types.
## Trigger

- **Webhook** `POST /webhook/site-chat` `webhookId: universal-site-agent` `responseMode: responseNode` (`n8n-nodes-base.webhook` 2). Body: `{message, text, query, input, sessionId, session_id, siteUrl, siteName, brandVoice, language}`. `Code: Config & Normalize` normalizes to `{sanitizedMessage, sessionId, siteUrl, siteName, brandVoice}` with `$env` fallback.

Example:

```bash
curl -X POST http://localhost:5678/webhook/site-chat -H "Content-Type: application/json" \
  -d '{"message":"Do you ship to Berlin?","sessionId":"sess_123","siteUrl":"https://example.com","siteName":"Example"}'
# -> {"ok":true,"answer":"Yes, we ship...","confidence":0.92,"intent":"answer","language":"en"}
```
## Nodes

| # | Name | Type | Purpose |
|---|---|---|---|
| 1 | Webhook Site Chat | `n8n-nodes-base.webhook` 2 | `POST /webhook/site-chat` `responseMode: responseNode` `webhookId universal-site-agent` |
| 2 | Code: Config & Normalize | `n8n-nodes-base.code` 2 | Normalize `sessionId/siteUrl/siteName/brandVoice` with `$env` fallback, sanitize 4k |
| 3 | Postgres Rate Limit Check | `n8n-nodes-base.postgres` 2.4 | `COUNT(*) FROM chat_history WHERE session_id=$1 AND created_at > NOW()-1min` |
| 4 | IF Rate Limited | `n8n-nodes-base.if` 2 | `cnt >=10` → true |
| 5 | Respond Blocked 429 | `n8n-nodes-base.respondToWebhook` 1.1 | `429 {ok:false, error:rate_limited}` |
| 6 | Code Guardrails | `n8n-nodes-base.code` 2 | Regex injection filter (`ignore previous instructions`, `DROP TABLE`, `<script`) |
| 7 | IF Guardrails Blocked | `n8n-nodes-base.if` 2 | `blocked==true` → true |
| 8 | Respond Blocked 403 | `n8n-nodes-base.respondToWebhook` 1.1 | `403 {error:blocked}` |
| 9 | Postgres Load History | `n8n-nodes-base.postgres` 2.4 | `SELECT * FROM chat_history WHERE session_id=$1 ORDER BY created_at DESC LIMIT 20` |
| 10 | Code Build History | `n8n-nodes-base.code` 2 | Join history `role: message` for Agent context |
| 11 | Window Buffer Memory | `@n8n/n8n-nodes-langchain.memoryBufferWindow` 1.3 | `sessionKey={{$('Code: Config & Normalize').item.json.sessionId}}` `window 20` |
| 12 | AI Agent | `@n8n/n8n-nodes-langchain.agent` 1.8 | `text={{sanitizedMessage}}` system includes `siteName/brandVoice` + JSON spec `{answer,confidence,intent,language,needs_handoff,lead,ticket}` |
| 13 | OpenAI Chat Model | `@n8n/n8n-nodes-langchain.lmChatOpenAi` 1.2 | `inclusionai/ling-3.0-flash-fin:free` via `https://openrouter.ai/api/v1` cred `2a2b3c4d...` |
| 14 | Embeddings OpenAI | `@n8n/n8n-nodes-langchain.embeddingsOpenAi` 1.2 | `text-embedding-3-small` cred `2a2b3c4d...` |
| 15 | Postgres PGVector Store | `@n8n/n8n-nodes-langchain.vectorStorePGVector` 1.3 | `table site_embeddings` |
| 16 | Vector Store Tool | `@n8n/n8n-nodes-langchain.toolVectorStore` 1.1 | `topK 5` site KB search |
| 17 | Postgres Writer Tool | `@n8n/n8n-nodes-langchain.toolCode` 1 | Persist chat/lead/ticket |
| 18 | HTTP Site API Tool | `@n8n/n8n-nodes-langchain.toolCode` 1 | Live site API `{{siteUrl}}/api/*` |
| 19 | Calculator Tool | `@n8n/n8n-nodes-langchain.toolCalculator` 1 | Math/prices/dates |
| 20 | Code Sanitize Tool | `@n8n/n8n-nodes-langchain.toolCode` 1 | Strip HTML, trim 4k |
| 21 | IF KB Hit | `n8n-nodes-base.if` 2 | `output isNotEmpty` → has context |
| 22 | HTTP DuckDuckGo Search | `n8n-nodes-base.httpRequest` 4.2 | Fallback `https://api.duckduckgo.com/?q=...&format=json` |
| 23 | Code Rerank | `n8n-nodes-base.code` 2 | Merge DuckDuckGo `AbstractText` with Agent output |
| 24 | Code Parse Output | `n8n-nodes-base.code` 2 | `JSON.parse({answer,confidence,intent,language,needs_handoff,lead,ticket})` |
| 25 | Switch Intent | `n8n-nodes-base.switch` 3.2 | `intent` → `answer|lead|ticket|handoff` |
| 26 | IF Handoff Required | `n8n-nodes-base.if` 2 | `needs_handoff==true` |
| 27 | Slack Notify #support | `n8n-nodes-base.slack` 1.3 | `#support` handoff |
| 28 | Telegram Notify Admin | `n8n-nodes-base.telegram` 1.2 | admin `chatId $env.TELEGRAM_ADMIN_ID` |
| 29 | Postgres Insert Chat History | `n8n-nodes-base.postgres` 2.4 | `INSERT chat_history` user+assistant |
| 30 | Postgres Insert Lead | `n8n-nodes-base.postgres` 2.4 | `INSERT leads` |
| 31 | Postgres Insert Ticket | `n8n-nodes-base.postgres` 2.4 | `INSERT tickets` |
| 32 | HTTP Site API Write | `n8n-nodes-base.httpRequest` 4.2 | `POST {{siteUrl}}/api/crm/lead` `continueOnFail:true` |
| 33 | Google Sheets Analytics | `n8n-nodes-base.googleSheets` 4.4 | `append Analytics {sessionId,intent,confidence,language,answer,timestamp}` |
| 34 | Code Format Final Response | `n8n-nodes-base.code` 2 | `formatted` markdown-lite `<b>`, `[link]` |
| 35 | Respond Success 200 | `n8n-nodes-base.respondToWebhook` 1.1 | `200 {ok,answer,formatted,confidence,intent,language,sessionId}` |
| 36 | IF Lead Exists | `n8n-nodes-base.if` 2 | `lead.email isNotEmpty` |
| 37 | IF Ticket Needed | `n8n-nodes-base.if` 2 | `ticket.subject isNotEmpty` |
| 38 | Merge Handoff Results | `n8n-nodes-base.merge` 3.1 | `combine multiplex` → unify branches |
## Flow

```
POST /webhook/site-chat {message, sessionId, siteUrl}
  |
  v
Code: Config & Normalize ( $env fallback, sanitizedMessage, sessionId )
  |
  v
Postgres Rate Limit Check --IF >=10/min--> Respond 429
  | false
  v
Code Guardrails --IF blocked--> Respond 403
  | false
  v
Postgres Load History -> Code Build History -> Window Buffer Memory (sessionKey=sessionId, 20)
  |
  v
AI Agent (text=sanitizedMessage, system=siteName/brandVoice + JSON spec)
  |  ai_languageModel: OpenAI Chat Model (ling-3.0-flash via OpenRouter)
  |  ai_memory: Window Buffer Memory (20)
  |  ai_tool: Vector Store Tool (topK5 -> PGVector site_embeddings + Embeddings text-embedding-3-small)
  |        : Postgres Writer Tool, HTTP Site API Tool, Calculator, Code Sanitize
  v $json.output
IF KB Hit --false--> HTTP DuckDuckGo -> Code Rerank --\
  | true (has context)                              |
  v                                                 v
Code Parse Output ({answer,confidence,intent,language,needs_handoff,lead,ticket})
  |
  v
Switch Intent (answer/lead/ticket/handoff)
  |-> answer -> IF Handoff Required --false--> Postgres Insert Chat History --\
  |-> lead   -> IF Lead Exists -> Postgres Insert Lead -> HTTP Site API Write --+--> Merge Handoff Results
  |-> ticket -> IF Ticket Needed -> Postgres Insert Ticket -> Google Sheets --+--->|
  |-> handoff-> IF Handoff Required --true--> Slack #support + Telegram admin -----/
  |
  v
Code Format Final Response (markdown-lite) -> Respond Success 200 {ok,answer,formatted,confidence,intent,language,sessionId}
```

Connections: main linear as above, `ai_languageModel: OpenAI -> Agent`, `ai_memory: Window Buffer Memory -> Agent`, `ai_tool: 5 tools -> Agent`, `ai_vectorStore: PGVector -> Vector Store Tool`, `ai_embedding: Embeddings -> PGVector`.
## Purpose

Production site chatbot that works for **any** site without code forks: ingest once (PDF/MD/TXT + sitemap HTML → `site_embeddings`), then answer from KB with LLM, capture leads/tickets, and escalate to humans via Slack/Telegram while logging to Postgres and Sheets. Single workflow, env-driven.

## Where to use (any site)

- Marketing site `example.com` → embed `widget.html` (set `window.SITE_CHAT_CONFIG.webhookUrl` to your n8n `/webhook/site-chat`), ingest `https://example.com/sitemap.xml` + `/data/site_kb` PDFs; answers grounded in docs.
- SaaS app → call `POST /webhook/site-chat` from your backend (Next.js, Django) with `sessionId=user.id`, render `answer` in your own UI; replace Slack with your helpdesk API via `HTTP Site API Write`.
- E-commerce → leads (`intent=lead`) flow to `leads` table + `POST /api/crm/lead` + Sheets `Analytics`; tickets (`intent=ticket`) to `tickets` + human handoff; `needs_handoff` true triggers Slack/Telegram immediately.
## Credentials

| Name | Type | ID | Where used |
|---|---|---|---|
| OpenAI account | `openAiApi` | `2a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5e` | `OpenAI Chat Model` (`ling-3.0-flash-fin:free` via `https://openrouter.ai/api/v1`), `Embeddings OpenAI` (`text-embedding-3-small`) |
| Postgres account | `postgres` | `b1c2d3e4-f5a6-4a7b-8c9d-0e1f2a3b4c5d` | `Postgres Rate Limit Check`, `Postgres Load History`, `PGVector Store` (`site_embeddings`), `Postgres Insert*` |
| Telegram account | `telegramApi` | `1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d` | `Telegram Notify Admin` |
| Slack account | `slackApi` | `3a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c6d` | `Slack Notify #support` |
| Google Sheets account | `googleSheetsOAuth2Api` | `4a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c6e` | `Google Sheets Analytics` (`Analytics` sheet) |
## Env vars

| Var | Example | Purpose |
|---|---|---|
| `SITE_URL` | `https://example.com` | Fallback for `siteUrl` when widget not sending; also used in ingest sitemap `{{siteUrl}}/sitemap.xml` and `HTTP Site API Write` `{{siteUrl}}/api/crm/lead` |
| `SITE_NAME` | `Example Inc` | Brand in Agent systemMessage |
| `BRAND_VOICE` | `helpful, concise, friendly` | Tone in systemMessage |
| `OPENAI_API_KEY` | `sk-or-v1-...` | OpenRouter or OpenAI key for `openAiApi` |
| `POSTGRES_*` / `DATABASE_URL` | `n8n/n8n_password@127.0.0.1:5433/n8n` | Postgres for pgvector + history |
| `SLACK_CHANNEL` | `#support` | Slack channel (or set in node) |
| `TELEGRAM_ADMIN_ID` | `123456789` | Telegram admin chatId |
| `WEBHOOK_URL` | `http://localhost:5678/` | n8n webhook base |
## Quick start

```bash
cp ../.env.example ../.env  # set OPENAI_API_KEY, POSTGRES_*, SITE_URL, SITE_NAME
docker compose up -d  # n8n :5678, postgres :5433
# n8n UI http://localhost:5678 -> Credentials -> OpenAI + Postgres + Telegram + Slack + Google Sheets OAuth2
# DB init
psql postgresql://n8n:n8n_password@127.0.0.1:5433/n8n -f universal-site-agent/sql/init.sql
# or docker: docker exec -i n8n-pgvector psql -U n8n -d n8n < universal-site-agent/sql/init.sql
# Verify
psql postgresql://n8n:n8n_password@127.0.0.1:5433/n8n -c "SELECT * FROM pg_extension WHERE extname='vector'; SELECT to_regclass('site_embeddings');"
# Import
# UI: Workflows -> Import from File -> universal-site-agent/workflow.json + ingest.json -> Activate
# CLI:
docker cp universal-site-agent/workflow.json n8n-demo:/tmp/w.json
docker exec n8n-demo n8n import:workflow --input=/tmp/w.json
docker cp universal-site-agent/ingest.json n8n-demo:/tmp/i.json
docker exec n8n-demo n8n import:workflow --input=/tmp/i.json
# Ingest: put PDFs/MD/TXT into ./data/site_kb or set SITE_URL sitemap, then in n8n execute ingest.json via Manual Trigger
# Test chat
curl -X POST http://localhost:5678/webhook/site-chat -H "Content-Type: application/json" \
  -d '{"message":"Hello, what do you do?","sessionId":"test_123","siteUrl":"https://example.com","siteName":"Example"}'
# -> {"ok":true,"answer":"...","intent":"answer","confidence":0.9}
# Widget: copy widget.html snippet into your site <head> or serve as static, set window.SITE_CHAT_CONFIG.webhookUrl
```
## Gotchas

- **`No prompt specified` (AI Agent)** — After Agent, `$json` is `{output}`, not webhook body. `AI Agent.text` must be `={{ $('Code: Config & Normalize').item.json.sanitizedMessage }}` (or `{{ $json.sanitizedMessage }}` before Agent). Never use `{{ $json.body.message }}` after Agent; use `{{ $('Webhook Site Chat').item.json.body.message }}` or `{{ $('Code: Config & Normalize').item.json.sanitizedMessage }}`.

- **`chat_id is empty` or `sessionId empty`** — `Window Buffer Memory.sessionKey` and `Postgres` inserts must use `={{ $('Code: Config & Normalize').item.json.sessionId }}` with `sessionIdType: customKey` and `contextWindowLength: 20`. After Agent, `$json.sessionId` is only available if you preserved it via `Code Parse Output`; always reference the Config node for session.

- **`429 Too Many Requests`** — Client hit `>=10/min` per `sessionId` via `Postgres Rate Limit Check` (`chat_history` count in last minute). Slow down or increase threshold in `IF Rate Limited` (edit `rightValue: 10`).

- **`403 Blocked` (guardrails)** — Injection filter matched `ignore previous instructions`, `DROP TABLE`, `<script`, etc. Check `Code Guardrails` `blockedPatterns` and adjust if false positive; legitimate messages with code snippets may trigger `DROP TABLE` rule.

- **`ECONNREFUSED / ENOTFOUND` for `POST {{siteUrl}}/api/crm/lead`** — `HTTP Site API Write` has `continueOnFail: true` so workflow still succeeds via Postgres/Sheets, but your CRM is unreachable. Verify `SITE_URL` is reachable from `n8n` container (`docker exec n8n-demo wget -qO- $SITE_URL/api/crm/lead`); for `host` network use `127.0.0.1`, for bridge use `host.docker.internal`.

- **Vector `1536` vs `3072` mismatch** — `site_embeddings` must be `vector(1536)` for `text-embedding-3-small`. If you switch to `text-embedding-3-large`, recreate table with `vector(3072)` and update both ingest + main `Embeddings OpenAI` nodes.

- **OpenRouter `baseURL`** — `OpenAI Chat Model` needs `options.baseURL: https://openrouter.ai/api/v1` with credential `openAiApi` `sk-or-v1-...`. For direct OpenAI, leave baseURL empty and use `gpt-4o-mini`.

## Showcase

Real execution proof — see [showcase/README.md](showcase/README.md):
- `showcase/widget-demo.png` — floating widget demo
- `showcase/site-chat-execution.png` — n8n execution success
- `showcase/handoff-proof.png` — Slack/Telegram handoff proof
- `showcase/db-widget-proof.png` — DB and widget proof

## License

MIT - see [LICENSE](../LICENSE)
