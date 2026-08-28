-- universal-site-agent init.sql
-- skeleton placeholder structure
-- Enable pgvector (requires pgvector/pgvector:pg16 image)
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- site_embeddings: RAG vector store for site KB (1536 dims for text-embedding-3-small)
CREATE TABLE IF NOT EXISTS site_embeddings (
  id BIGSERIAL PRIMARY KEY,
  embedding vector(1536),
  text TEXT NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  source TEXT,
  url TEXT,
  chunk_index INT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- chat_history: per-session conversation log + rate limit source
CREATE TABLE IF NOT EXISTS chat_history (
  id BIGSERIAL PRIMARY KEY,
  session_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
  message TEXT NOT NULL,
  intent TEXT,
  confidence REAL,
  language TEXT,
  needs_handoff BOOLEAN DEFAULT FALSE,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_chat_history_session ON chat_history(session_id);
CREATE INDEX IF NOT EXISTS idx_chat_history_created ON chat_history(created_at);
-- Rate limit helper: recent messages per session in last minute
-- SELECT COUNT(*) FROM chat_history WHERE session_id = $1 AND created_at > NOW() - INTERVAL '1 minute';
-- leads: captured CRM leads from Switch intent=lead or AI extraction
CREATE TABLE IF NOT EXISTS leads (
  id BIGSERIAL PRIMARY KEY,
  session_id TEXT,
  name TEXT,
  email TEXT,
  phone TEXT,
  company TEXT,
  message TEXT,
  source TEXT,
  score INT,
  tier TEXT CHECK (tier IN ('hot','warm','cold')),
  reason TEXT,
  next_step TEXT,
  intent TEXT,
  confidence REAL,
  language TEXT,
  status TEXT DEFAULT 'new',
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_leads_email ON leads(email);
CREATE INDEX IF NOT EXISTS idx_leads_session ON leads(session_id);
CREATE INDEX IF NOT EXISTS idx_leads_tier ON leads(tier);
CREATE INDEX IF NOT EXISTS idx_leads_created ON leads(created_at);
-- tickets: support tickets from Switch intent=ticket or handoff
CREATE TABLE IF NOT EXISTS tickets (
  id BIGSERIAL PRIMARY KEY,
  session_id TEXT,
  subject TEXT,
  description TEXT,
  priority TEXT CHECK (priority IN ('low','medium','high','urgent')),
  status TEXT DEFAULT 'open' CHECK (status IN ('open','in_progress','resolved','closed')),
  assignee TEXT,
  email TEXT,
  name TEXT,
  intent TEXT,
  language TEXT,
  source TEXT DEFAULT 'site-chat',
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tickets_session ON tickets(session_id);
CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);
CREATE INDEX IF NOT EXISTS idx_tickets_priority ON tickets(priority);
CREATE INDEX IF NOT EXISTS idx_tickets_created ON tickets(created_at);
-- IVFFlat index for site_embeddings (requires data; n8n auto-creates but we optimize)
-- NOTE: ivfflat needs at least some rows; create after ingest or use HNSW for empty.
-- For production large KB: CREATE INDEX ON site_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
-- Alternative for immediate use (works empty): HNSW
CREATE INDEX IF NOT EXISTS idx_site_embeddings_embedding_hnsw
  ON site_embeddings USING hnsw (embedding vector_cosine_ops);
-- Fallback ivfflat (will be built after rows inserted) — commented until ingest:
-- CREATE INDEX IF NOT EXISTS idx_site_embeddings_embedding_ivfflat ON site_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX IF NOT EXISTS idx_site_embeddings_source ON site_embeddings(source);
CREATE INDEX IF NOT EXISTS idx_site_embeddings_url ON site_embeddings(url);
CREATE INDEX IF NOT EXISTS idx_site_embeddings_created ON site_embeddings(created_at);
-- Optional seed / verification queries
-- Verify: SELECT * FROM site_embeddings LIMIT 1;
-- Verify rate limit: SELECT session_id, COUNT(*) FROM chat_history WHERE created_at > NOW() - INTERVAL '1 minute' GROUP BY session_id;
-- Verify pgvector: SELECT * FROM pg_extension WHERE extname = 'vector';
-- Reset helpers (dev only):
-- TRUNCATE site_embeddings, chat_history, leads, tickets RESTART IDENTITY;
-- DROP INDEX IF EXISTS idx_site_embeddings_embedding_hnsw;
