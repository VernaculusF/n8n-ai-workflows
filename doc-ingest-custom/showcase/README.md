# Showcase — doc-ingest-custom (n8n-nodes-doc-ingest)

Custom node `n8n-nodes-doc-ingest.docIngest` in `../workflow.json` — single-node replacement for 5-node chain.

## What it proves

- **Webhook URL ingest** `POST /webhook/doc-ingest { url: "https://example.com", collection: "documents" }` → `Document Ingest (source:url)` → pgvector `documents` `vector(1536)` `inserted == chunksIngested`
- **Text ingest** `Manual Trigger` → `Document Ingest (source:text)` inline demo
- **Binary ingest** `POST /webhook/doc-ingest-binary` `multipart data=@file.pdf` → `Document Ingest (source:binary)`
- Same table as `rag-doc-search` — query with `rag-doc-search/workflow.json` Vector Store Tool `topK 4` works without changes

## How to reproduce

```bash
# 1. Build and install custom node (once)
cd /home/jester/Documents/github/n8n-nodes-doc-ingest && npm install && npm run build
docker exec n8n-demo npm install --prefix /home/node/.n8n/custom n8n-nodes-doc-ingest
docker restart n8n-demo && sleep 5

# 2. Import
docker cp doc-ingest-custom/workflow.json n8n-demo:/tmp/w.json
docker exec n8n-demo n8n import:workflow --input=/tmp/w.json
# UI → Credentials → openAiApi + pgvectorApi → Activate

# 3. Webhook URL test
curl -X POST http://localhost:5678/webhook/doc-ingest -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","fileType":"html"}'
# -> {"ok":true,"collection":"documents","inserted":1,"chunksIngested":1}

# 4. Binary test
curl -X POST http://localhost:5678/webhook/doc-ingest-binary -F "data=@./sample.pdf"
# -> {"source":"binary","inserted":...}

# 5. Verify pgvector
docker exec n8n-pgvector psql -U n8n -d n8n -c "SELECT count(*) FROM documents WHERE metadata->>'source'='doc-ingest-custom';"
docker exec n8n-pgvector psql -U n8n -d n8n -c "SELECT left(content,80), metadata FROM documents ORDER BY id DESC LIMIT 3;"
```

## Artifacts (to be added after execution)

- `webhook-curl.png` — curl POST /webhook/doc-ingest → 200 {ok, inserted}
- `pgvector-proof.png` — psql count(*) proof
- `execution.png` — n8n Execution 200 success

Until real run, see `../preview.png` for graph layout and `../README.md` for node table.
