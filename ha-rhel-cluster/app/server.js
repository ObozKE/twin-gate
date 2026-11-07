// ==============================================================================
// ha-rhel-cluster/app/server.js
// High-Availability Idempotent Transaction API
// Production-grade Express microservice with Prometheus instrumentation
// ==============================================================================

const express = require('express');
const os = require('os');
const { Pool } = require('pg');
const client = require('prom-client');
const { validate: validateUuid } = require('uuid');

const app = express();
app.use(express.json());

// Configuration from Environment Variables
const PORT = process.env.PORT || 3000;
const BACKEND_NAME = process.env.BACKEND_NAME || `api-${os.hostname()}`;
const DB_HOST = process.env.DB_HOST || '127.0.0.1';
const DB_PORT = parseInt(process.env.DB_PORT || '5432', 10);
const DB_USER = process.env.DB_USER || 'app_user';
const DB_PASSWORD = process.env.DB_PASSWORD || 'TxSecurePass2026!';
const DB_NAME = process.env.DB_NAME || 'transactions_db';
const USE_MOCK_DB = process.env.USE_MOCK_DB === 'true';

// ------------------------------------------------------------------------------
// 1. Prometheus Metrics Configuration
// ------------------------------------------------------------------------------
const register = new client.Registry();
client.collectDefaultMetrics({ register, prefix: 'node_api_' });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests processed',
  labelNames: ['method', 'path', 'status', 'backend'],
  registers: [register],
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Histogram of HTTP request latencies in seconds',
  labelNames: ['method', 'path', 'status', 'backend'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
  registers: [register],
});

const transactionsTotal = new client.Counter({
  name: 'transactions_total',
  help: 'Total financial transactions processed with idempotency classification',
  labelNames: ['status', 'is_replay', 'backend'],
  registers: [register],
});

// Middleware: Measure request duration & attach X-Backend header to all responses
app.use((req, res, next) => {
  const start = process.hrtime();
  res.setHeader('X-Backend', BACKEND_NAME);

  res.on('finish', () => {
    const diff = process.hrtime(start);
    const durationSeconds = diff[0] + diff[1] / 1e9;
    const path = req.route ? req.baseUrl + req.route.path : req.path;
    const status = res.statusCode.toString();

    httpRequestsTotal.inc({ method: req.method, path, status, backend: BACKEND_NAME });
    httpRequestDuration.observe({ method: req.method, path, status, backend: BACKEND_NAME }, durationSeconds);
  });

  next();
});

// ------------------------------------------------------------------------------
// 2. Database Connection Pool & In-Memory Fallback
// ------------------------------------------------------------------------------
let pool = null;
const memoryTxStore = new Map();

if (!USE_MOCK_DB) {
  pool = new Pool({
    host: DB_HOST,
    port: DB_PORT,
    user: DB_USER,
    password: DB_PASSWORD,
    database: DB_NAME,
    max: 20,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 2000,
  });

  pool.on('error', (err) => {
    console.error(`[${new Date().toISOString()}] Unexpected Postgres Pool error:`, err.message);
  });
}

// ------------------------------------------------------------------------------
// 3. API Endpoints
// ------------------------------------------------------------------------------

/**
 * GET /health
 * Active health check endpoint used by HAProxy option httpchk
 */
app.get('/health', async (req, res) => {
  if (USE_MOCK_DB) {
    return res.status(200).json({
      status: 'UP',
      uptime_seconds: process.uptime(),
      backend: BACKEND_NAME,
      database: 'MOCK_OK',
    });
  }

  try {
    const clientConn = await pool.connect();
    await clientConn.query('SELECT 1');
    clientConn.release();

    res.status(200).json({
      status: 'UP',
      uptime_seconds: process.uptime(),
      backend: BACKEND_NAME,
      database: 'CONNECTED',
      timestamp: new Date().toISOString(),
    });
  } catch (err) {
    res.status(503).json({
      status: 'DOWN',
      backend: BACKEND_NAME,
      database: 'UNREACHABLE',
      error: err.message,
    });
  }
});

/**
 * GET /whoami
 * Returns node identity for verifying HAProxy load-balancing distribution
 */
app.get('/whoami', (req, res) => {
  res.status(200).json({
    hostname: os.hostname(),
    backend: BACKEND_NAME,
    pid: process.pid,
    node_version: process.version,
    uptime_seconds: Math.floor(process.uptime()),
    client_ip: req.headers['x-forwarded-for'] || req.socket.remoteAddress,
  });
});

/**
 * POST /transactions
 * Carrier-grade idempotent financial transaction submission
 * Guarantees exactly-once processing using database unique constraints
 */
app.post('/transactions', async (req, res) => {
  const idempotencyKey = req.header('Idempotency-Key') || req.body.idempotency_key;
  const { account_id, amount, tx_type = 'DEBIT', currency = 'KES' } = req.body;

  // Validation
  if (!idempotencyKey || !validateUuid(idempotencyKey)) {
    return res.status(400).json({
      error: 'BAD_REQUEST',
      message: 'A valid UUIDv4 Idempotency-Key header or idempotency_key body parameter is required.',
    });
  }

  const numericAmount = parseFloat(amount);
  if (isNaN(numericAmount) || numericAmount <= 0) {
    return res.status(400).json({
      error: 'BAD_REQUEST',
      message: 'Amount must be a positive numeric value.',
    });
  }

  if (!account_id) {
    return res.status(400).json({
      error: 'BAD_REQUEST',
      message: 'account_id is required.',
    });
  }

  // Handle Mock DB Mode (used for standalone testability)
  if (USE_MOCK_DB) {
    if (memoryTxStore.has(idempotencyKey)) {
      const existing = memoryTxStore.get(idempotencyKey);
      transactionsTotal.inc({ status: 'committed', is_replay: 'true', backend: BACKEND_NAME });
      return res.status(200).json({
        ...existing,
        is_replay: true,
        served_by: BACKEND_NAME,
      });
    }

    const newTx = {
      id: memoryTxStore.size + 1,
      idempotency_key: idempotencyKey,
      account_id,
      amount: numericAmount,
      currency,
      tx_type,
      status: 'COMMITTED',
      created_at: new Date().toISOString(),
      backend_node: BACKEND_NAME,
    };
    memoryTxStore.set(idempotencyKey, newTx);
    transactionsTotal.inc({ status: 'committed', is_replay: 'false', backend: BACKEND_NAME });
    return res.status(201).json({
      ...newTx,
      is_replay: false,
      served_by: BACKEND_NAME,
    });
  }

  // Real Database Execution via PostgreSQL
  try {
    // Atomic insert with conflict detection
    const insertQuery = `
      INSERT INTO transactions (idempotency_key, account_id, amount, currency, tx_type, status, backend_node)
      VALUES ($1, $2, $3, $4, $5, 'COMMITTED', $6)
      ON CONFLICT (idempotency_key) DO NOTHING
      RETURNING id, idempotency_key, account_id, amount, currency, tx_type, status, created_at, backend_node;
    `;

    const result = await pool.query(insertQuery, [
      idempotencyKey,
      account_id,
      numericAmount,
      currency,
      tx_type,
      BACKEND_NAME,
    ]);

    if (result.rows.length > 0) {
      // Fresh insertion
      transactionsTotal.inc({ status: 'committed', is_replay: 'false', backend: BACKEND_NAME });
      return res.status(201).json({
        ...result.rows[0],
        is_replay: false,
        served_by: BACKEND_NAME,
      });
    }

    // Conflict encountered: retrieve existing idempotent transaction
    const selectQuery = `
      SELECT id, idempotency_key, account_id, amount, currency, tx_type, status, created_at, backend_node
      FROM transactions
      WHERE idempotency_key = $1;
    `;
    const existingResult = await pool.query(selectQuery, [idempotencyKey]);

    if (existingResult.rows.length === 0) {
      // Edge case: concurrent transaction rolled back
      return res.status(500).json({ error: 'CONCURRENCY_ERROR', message: 'Transaction conflict retry failed.' });
    }

    transactionsTotal.inc({ status: 'committed', is_replay: 'true', backend: BACKEND_NAME });
    return res.status(200).json({
      ...existingResult.rows[0],
      is_replay: true,
      served_by: BACKEND_NAME,
    });
  } catch (err) {
    console.error(`[${new Date().toISOString()}] Transaction error:`, err);
    res.status(500).json({
      error: 'DATABASE_ERROR',
      message: err.message,
    });
  }
});

/**
 * GET /transactions/count
 * Verifies exact transaction count in the database
 */
app.get('/transactions/count', async (req, res) => {
  if (USE_MOCK_DB) {
    return res.status(200).json({
      count: memoryTxStore.size,
      backend: BACKEND_NAME,
    });
  }

  try {
    const result = await pool.query('SELECT COUNT(*)::bigint AS count FROM transactions;');
    res.status(200).json({
      count: parseInt(result.rows[0].count, 10),
      backend: BACKEND_NAME,
    });
  } catch (err) {
    res.status(500).json({ error: 'DATABASE_ERROR', message: err.message });
  }
});

/**
 * GET /metrics
 * Exposes Prometheus scraping endpoint
 */
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
});

// ------------------------------------------------------------------------------
// 4. Graceful Shutdown & Server Startup
// ------------------------------------------------------------------------------
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`[${new Date().toISOString()}] ${BACKEND_NAME} listening on port ${PORT}`);
});

const gracefulShutdown = (signal) => {
  console.log(`[${new Date().toISOString()}] Received ${signal}. Initiating graceful shutdown...`);
  server.close(async () => {
    console.log(`[${new Date().toISOString()}] HTTP server closed.`);
    if (pool) {
      await pool.end();
      console.log(`[${new Date().toISOString()}] Postgres pool drained.`);
    }
    process.exit(0);
  });

  // Force exit if shutdown hangs beyond 5 seconds
  setTimeout(() => {
    console.error(`[${new Date().toISOString()}] Forced termination after timeout.`);
    process.exit(1);
  }, 5000);
};

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

module.exports = { app, server, pool };
