# doc-ingest-custom — Document Ingest via n8n-nodes-doc-ingest

`workflow.json` `ingest-binary.json` `preview.png` — demo of the custom community node `n8n-nodes-doc-ingest` (`n8n-nodes-doc-ingest.docIngest`).

**Case:** ingest any PDF/DOCX/HTML/URL/text into `pgvector`/`qdrant`/`supabase` with a **single node** instead of the 5-node chain (`Read Binary Files → Extract from File → Default Data Loader → Recursive Splitter → PGVector Store`).

**Graph:**
- `Webhook POST /webhook/doc-ingest → Document Ingest (source: url, documentUrl = {{$json.body.url}}) → Respond {ok, inserted, chunksIngested}`
- `Manual Trigger → Document Ingest (source: text, documentText = demo) → (no respond, inspect execution)`
- `ingest-binary.json`: `Webhook POST /webhook/doc-ingest-binary (binary) → Document Ingest (source: binary) → Respond`

Preview: `preview.png` (3756×1956 dark).

## Nodes

| Node | Type | Purpose |
|---|---|---|
| `Webhook` | `n8n-nodes-base.webhook` 2 | `POST /webhook/doc-ingest` `{ url, collection?, fileType? }` `responseMode: responseNode` |
| `Document Ingest` | `n8n-nodes-doc-ingest.docIngest` 1 | `source:url` `chunkSize 1000` `chunkOverlap 200` `embeddingModel text-embedding-3-small` `vectorStore pgvector` `collection documents` `additionalFields.metadataJson` |
| `Respond to Webhook` | `n8n-nodes-base.respondToWebhook` 1.1 | Returns `{ok, collection, inserted, chunksIngested, totalChunks, embeddingModel}` |
| `Manual Trigger` | `n8n-nodes-base.manualTrigger` 1 | Inline demo ingest (text source) |
| `Document Ingest (text)` | `n8n-nodes-doc-ingest.docIngest` 1 | `source:text` `800/100` same `documents` table |
| `ingest-binary.json: Webhook (binary)` | `n8n-nodes-base.webhook` 2 | `POST /webhook/doc-ingest-binary` `multipart/form-data` with `data` binary property |
| `Document Ingest (binary)` | `n8n-nodes-doc-ingest.docIngest` 1 | `source:binary` `binaryPropertyName data` auto detect PDF/DOCX/HTML |

## Flow

```
POST /webhook/doc-ingest { url: "https://example.com/doc.pdf", collection: "documents" }
  → Document Ingest (url → fetch → stripHtml/extractText → split 1000/200 → OpenAI embeddings batch 50 → pgvector INSERT)
  → Respond 200 { ok: true, collection: "documents", inserted: 14, chunksIngested: 14 }

Manual Trigger
  → Document Ingest (text) → Execution output { source: "text", vectorStore: "pgvector", ... }

POST /webhook/doc-ingest-binary (multipart data=@file.pdf)
  → Document Ingest (binary) → Respond
```

## Why custom node vs 5-node chain

| 5-node chain (`rag-doc-search/ingest.json`) | Single `DocIngest` (`doc-ingest-custom/workflow.json`) |
|---|---|
| `Read Binary Files` + `Extract from File` + `Edit Fields` + `Default Data Loader` + `Text Splitter` + `PGVector Store` + `Embeddings OpenAI` (7 nodes) | `Document Ingest` (1 node, credentials `openAiApi`+`pgvectorApi`) |
| Manual `fileSelector: /data/pdfs/*.pdf`, needs `binaryPropertyName` wiring, separate `ai_document`/`ai_textSplitter`/`ai_embedding` edges | `source: binary/url/text`, `fileType: auto/pdf/docx/html/text`, `chunkSize/chunkOverlap`, `embeddingModel`, `batchSize`, `vectorStore`, `collectionName` in one panel |
| Separate `tableName` in PGVector node, metadata via `Edit Fields` | `additionalFields.metadataJson` + auto `stripHtml`, `returnAll/limit`, `continueOnFail` |
| Works without custom package | Requires `n8n-nodes-doc-ingest` installed (see below) |

Execution output is identical shape:

```json
{
  "source": "url",
  "vectorStore": "pgvector",
  "collection": "documents",
  "embeddingModel": "text-embedding-3-small",
  "documentLength": 12453,
  "totalChunks": 14,
  "chunksIngested": 14,
  "inserted": 14
}
```

## Credentials

- `openAiApi` (`apiKey`, optional `baseUrl: https://openrouter.ai/api/v1`) — for embeddings
- `pgvectorApi` (`host: 127.0.0.1`, `port: 5433`, `database: n8n`, `user: n8n`, `password: n8n_password`, `tableName: documents`, `dimensions: 1536`, `ssl: false`) — for host network; use `postgres:5432` for bridge
- `qdrantApi` / `supabaseApi` alternative when `vectorStore` is `qdrant`/`supabase`

Create in `n8n UI → Credentials`. IDs in JSON `2a2b3c4d...` / `3a2b3c4d...` are placeholders — replace on import.

## Install custom node

```bash
# Inside n8n container or ~/.n8n/custom
npm install n8n-nodes-doc-ingest
# or link local build
cd /home/jester/Documents/github/n8n-nodes-doc-ingest && npm run build
npm link
cd ~/.n8n/custom && npm link n8n-nodes-doc-ingest
# then restart n8n
docker restart n8n-demo
# Verify: n8n UI → Nodes → Document Ingest appears
```

`docker-compose.yml` already has `N8N_COMMUNITY_PACKAGES_ENABLED=true` and `N8N_CUSTOM_EXTENSIONS=/home/node/.n8n/custom`.

## Quick start

```bash
# 1. Build and install custom node (once)
cd /home/jester/Documents/github/n8n-nodes-doc-ingest && npm install && npm run build
docker exec n8n-demo npm install --prefix /home/node/.n8n/custom n8n-nodes-doc-ingest
docker restart n8n-demo

# 2. Import workflow
docker cp doc-ingest-custom/workflow.json n8n-demo:/tmp/w.json
docker exec n8n-demo n8n import:workflow --input=/tmp/w.json
# then in UI assign openAiApi + pgvectorApi and Activate

# 3. Test URL ingest
curl -X POST http://localhost:5678/webhook/doc-ingest -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","fileType":"html","collection":"documents"}'
# -> {"ok":true,"inserted":3,"chunksIngested":3,"totalChunks":3}

# 4. Test text ingest (Manual Trigger in UI → Execute)

# 5. Test binary ingest
curl -X POST http://localhost:5678/webhook/doc-ingest-binary -F "data=@/path/to/file.pdf"
# -> {"source":"binary","inserted":...}

# 6. Verify pgvector
docker exec n8n-pgvector psql -U n8n -d n8n -c "SELECT count(*), left(content,60) FROM documents GROUP BY left(content,60) LIMIT 5;"
docker exec n8n-pgvector psql -U n8n -d n8n -c "SELECT id, metadata->>'source' as source, char_length(content) FROM documents ORDER BY id DESC LIMIT 5;"
```

Query the ingested data with `rag-doc-search/workflow.json` (Vector Store Tool `topK 4` → same `documents` table) or `universal-site-agent` (ask via `/webhook/site-chat`).

## Environment

Same as `rag-doc-search`: `POSTGRES_HOST 127.0.0.1:5433`, `OPENAI_API_KEY`, `QDRANT_URL` if using `qdrant`.

## Gotchas

- `documentUrl` must be reachable from n8n container (host network helps for 127.0.0.1); for URL source the node does `helpers.httpRequest GET encoding arraybuffer`
- `metadataJson` must be valid JSON string; use `={\"source\": \"my-tag\"}` expression or plain `{"source":"x"}`
- `collectionName` sanitized `^[a-zA-Z_][a-zA-Z0-9_]*$` for pgvector; `dimensions` must match model (`1536` for `text-embedding-3-small`, `3072` for `large`)
- Install custom node before import — otherwise workflow shows `Unrecognized node type: n8n-nodes-doc-ingest.docIngest`
- Binary upload needs `Webhook → Binary Data: true` and field name `data`

## Related

- Source node: `../n8n-nodes-doc-ingest` — `nodes/DocIngest/DocIngest.node.ts` (chunking, embeddings batch, pgvector/qdrant/supabase upsert)
- 5-node alternative: `../rag-doc-search/ingest.json`
- Query side: `../rag-doc-search/workflow.json` (Telegram RAG) and `../universal-site-agent/workflow.json` (site RAG)

## Showcase

See `showcase/README.md` for execution proof (webhook curl + pgvector count).
