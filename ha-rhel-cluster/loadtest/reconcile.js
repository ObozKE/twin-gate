// ==============================================================================
// ha-rhel-cluster/loadtest/reconcile.js
// Client vs Database Financial Transaction Reconciliation Engine
// Proves Exactly-Once Semantics: Zero Duplicates, Zero Missing Transactions
// ==============================================================================

const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

const args = process.argv.slice(2);
function getArg(flag, defaultValue) {
  const index = args.indexOf(flag);
  return index !== -1 && args[index + 1] ? args[index + 1] : defaultValue;
}

const RESULTS_DIR = path.join(__dirname, 'results');

// Identify UUID file to reconcile
let uuidsFile = getArg('--file', null);
if (!uuidsFile) {
  // Find the latest confirmed-uuids-*.txt file in results/
  if (fs.existsSync(RESULTS_DIR)) {
    const files = fs.readdirSync(RESULTS_DIR)
      .filter((f) => f.startsWith('confirmed-uuids-') && f.endsWith('.txt'))
      .sort()
      .reverse();
    if (files.length > 0) {
      uuidsFile = path.join(RESULTS_DIR, files[0]);
    }
  }
}

if (!uuidsFile || !fs.existsSync(uuidsFile)) {
  console.error(`[FATAL] No confirmed UUIDs file found to reconcile. Specify with --file <path>`);
  process.exit(1);
}

const DB_HOST = getArg('--db-host', process.env.DB_HOST || '192.168.56.20');
const DB_PORT = parseInt(getArg('--db-port', process.env.DB_PORT || '5432'), 10);
const DB_USER = getArg('--db-user', process.env.DB_USER || 'app_user');
const DB_PASSWORD = getArg('--db-password', process.env.DB_PASSWORD || 'TxSecurePass2026!');
const DB_NAME = getArg('--db-name', process.env.DB_NAME || 'transactions_db');
const MOCK_DB_FILE = getArg('--mock-db', null);

async function runReconciliation() {
  console.log('======================================================================');
  console.log('>> FINANCIAL TRANSACTION RECONCILIATION AUDIT');
  console.log(`>> Client Confirmation File: ${uuidsFile}`);
  console.log(`>> Database Target:          ${MOCK_DB_FILE ? 'MOCK FILE (' + MOCK_DB_FILE + ')' : DB_HOST + ':' + DB_PORT + '/' + DB_NAME}`);
  console.log('======================================================================');

  // 1. Read Client Confirmed UUIDs
  const rawUuids = fs.readFileSync(uuidsFile, 'utf8')
    .split('\n')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

  const clientUuidSet = new Set(rawUuids);
  console.log(`>> Total Client-Confirmed Transactions: ${rawUuids.length}`);
  console.log(`>> Unique Client-Confirmed UUIDs:       ${clientUuidSet.size}`);

  if (rawUuids.length !== clientUuidSet.size) {
    console.warn(`[WARNING] Client confirmation log contains internal duplicates! Duplicates: ${rawUuids.length - clientUuidSet.size}`);
  }

  // 2. Fetch Database Records
  let dbRows = [];

  if (MOCK_DB_FILE) {
    // Read from mock JSON database dump
    const mockContent = JSON.parse(fs.readFileSync(MOCK_DB_FILE, 'utf8'));
    dbRows = mockContent.transactions || mockContent;
  } else {
    // Query live PostgreSQL instance
    const pool = new Pool({
      host: DB_HOST,
      port: DB_PORT,
      user: DB_USER,
      password: DB_PASSWORD,
      database: DB_NAME,
      connectionTimeoutMillis: 5000,
    });

    try {
      console.log('>> Connecting to PostgreSQL database...');
      const client = await pool.connect();
      const query = `
        SELECT id, idempotency_key::text, account_id, amount, currency, tx_type, status, created_at, backend_node
        FROM transactions;
      `;
      const result = await client.query(query);
      dbRows = result.rows;
      client.release();
      await pool.end();
    } catch (err) {
      console.error(`[FATAL] Unable to connect to PostgreSQL: ${err.message}`);
      process.exit(1);
    }
  }

  console.log(`>> Total Transactions In Database:      ${dbRows.length}`);

  // 3. Reconcile Records
  const dbUuidMap = new Map();
  const dbDuplicates = [];

  for (const row of dbRows) {
    const key = row.idempotency_key;
    if (dbUuidMap.has(key)) {
      dbDuplicates.push(key);
    } else {
      dbUuidMap.set(key, row);
    }
  }

  const missingInDb = [];
  for (const clientUuid of clientUuidSet) {
    if (!dbUuidMap.has(clientUuid)) {
      missingInDb.push(clientUuid);
    }
  }

  // Check for orphan transactions in DB that client never confirmed
  let orphanCount = 0;
  for (const [dbKey] of dbUuidMap) {
    if (!clientUuidSet.has(dbKey)) {
      orphanCount++;
    }
  }

  // 4. Verification Report
  console.log('\n----------------------------------------------------------------------');
  console.log('>> AUDIT VERIFICATION METRICS');
  console.log('----------------------------------------------------------------------');
  console.log(`Expected Client Transactions:  ${clientUuidSet.size}`);
  console.log(`Matched In PostgreSQL DB:      ${clientUuidSet.size - missingInDb.length}`);
  console.log(`Missing Transactions in DB:    ${missingInDb.length}`);
  console.log(`Duplicate Transactions in DB:  ${dbDuplicates.length}`);
  console.log(`Unmatched / Prior Run in DB:   ${orphanCount}`);
  console.log('----------------------------------------------------------------------');

  let passed = true;

  if (missingInDb.length > 0) {
    console.error(`[FAIL] MISSING TRANSACTIONS DETECTED! (${missingInDb.length} confirmed transactions lost!)`);
    console.error(`First 5 missing UUIDs:`, missingInDb.slice(0, 5));
    passed = false;
  } else {
    console.log(`[PASS] Zero lost transactions: 100% of client-confirmed transactions exist in DB.`);
  }

  if (dbDuplicates.length > 0) {
    console.error(`[FAIL] DUPLICATE TRANSACTIONS DETECTED! (${dbDuplicates.length} duplicates found in DB!)`);
    console.error(`Duplicate UUIDs:`, dbDuplicates.slice(0, 5));
    passed = false;
  } else {
    console.log(`[PASS] Zero duplicate transactions: UNIQUE idempotency constraint strictly preserved.`);
  }

  console.log('======================================================================');
  if (passed) {
    console.log('>> FINAL RECONCILIATION AUDIT: [PASS]');
    console.log('>> ZERO TRANSACTIONS LOST. EXACTLY-ONCE INTEGRITY PROVEN.');
    console.log('======================================================================');
    process.exit(0);
  } else {
    console.log('>> FINAL RECONCILIATION AUDIT: [FAIL]');
    console.log('======================================================================');
    process.exit(1);
  }
}

runReconciliation().catch((err) => {
  console.error('Fatal error during reconciliation:', err);
  process.exit(1);
});
