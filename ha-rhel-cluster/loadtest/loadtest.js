// ==============================================================================
// ha-rhel-cluster/loadtest/loadtest.js
// Carrier-Grade VRRP Failover Load Generator with Idempotency Retry Tracking
// Uses Undici Connection Pooling for Microsecond Connection Lifecycle Control
// ==============================================================================

const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');
const { Client, Pool } = require('undici');

// ------------------------------------------------------------------------------
// 1. CLI Arguments & Configuration
// ------------------------------------------------------------------------------
const args = process.argv.slice(2);
function getArg(flag, defaultValue) {
  const index = args.indexOf(flag);
  return index !== -1 && args[index + 1] ? args[index + 1] : defaultValue;
}

const TARGET_URL = getArg('--url', process.env.TARGET_URL || 'http://192.168.56.10:8080/transactions');
const TARGET_RATE = parseInt(getArg('--rate', process.env.TARGET_RATE || '200'), 10);
const DURATION_SEC = parseInt(getArg('--duration', process.env.DURATION_SEC || '30'), 10);
const TIMEOUT_MS = parseInt(getArg('--timeout', process.env.TIMEOUT_MS || '500'), 10);
const MAX_RETRIES = parseInt(getArg('--retries', process.env.MAX_RETRIES || '5'), 10);
const RETRY_BACKOFF_MS = parseInt(getArg('--backoff', process.env.RETRY_BACKOFF_MS || '50'), 10);

const parsedUrl = new URL(TARGET_URL);
const targetOrigin = parsedUrl.origin;
const targetPath = parsedUrl.pathname;

// Output directory
const RESULTS_DIR = path.join(__dirname, 'results');
if (!fs.existsSync(RESULTS_DIR)) {
  fs.mkdirSync(RESULTS_DIR, { recursive: true });
}

const RUN_TIMESTAMP = new Date().toISOString().replace(/[:.]/g, '-');
const CSV_FILE = path.join(RESULTS_DIR, `run-${RUN_TIMESTAMP}.csv`);
const SUMMARY_FILE = path.join(RESULTS_DIR, `run-${RUN_TIMESTAMP}-summary.json`);
const UUIDS_FILE = path.join(RESULTS_DIR, `confirmed-uuids-${RUN_TIMESTAMP}.txt`);

// Initialize CSV stream
const csvStream = fs.createWriteStream(CSV_FILE, { flags: 'a' });
csvStream.write('tx_uuid,status,http_code,attempts,total_latency_ms,first_node,final_node,is_replay,created_at\n');

const uuidsStream = fs.createWriteStream(UUIDS_FILE, { flags: 'a' });

// Initialize Undici Pool with tuned connection parameters
const httpClient = new Pool(targetOrigin, {
  connections: 50,
  pipelining: 1,
  keepAliveTimeout: 10000,
  keepAliveMaxTimeout: 30000,
});

// ------------------------------------------------------------------------------
// 2. Metrics & State Tracking
// ------------------------------------------------------------------------------
let isRunning = true;
let totalTransactionsScheduled = 0;
let totalConfirmedSuccess = 0;
let totalPermanentFailures = 0;
let totalRawAttempts = 0;
let totalRetryAttempts = 0;

// Failover detection tracking
let initialNodeObserved = null;
let firstFailTimestamp = null;
let firstSuccessOtherNodeTimestamp = null;
let failoverDetectedNode = null;

// Per-second sliding window counters
let secAttempts = 0;
let secSuccesses = 0;
let secFails = 0;
let secRetries = 0;
let secLatencies = [];
let secLbNodes = {};

// Global latency tracking for final summary
const allLatencies = [];

function recordLatency(ms) {
  secLatencies.push(ms);
  allLatencies.push(ms);
}

function calculatePercentiles(latencies) {
  if (latencies.length === 0) return { p50: 0, p95: 0, p99: 0 };
  const sorted = [...latencies].sort((a, b) => a - b);
  const p50 = sorted[Math.floor(sorted.length * 0.50)] || 0;
  const p95 = sorted[Math.floor(sorted.length * 0.95)] || 0;
  const p99 = sorted[Math.floor(sorted.length * 0.99)] || 0;
  return { p50: p50.toFixed(1), p95: p95.toFixed(1), p99: p99.toFixed(1) };
}

// ------------------------------------------------------------------------------
// 3. Request Execution & Idempotency Retry Logic
// ------------------------------------------------------------------------------
async function executeTransactionWithRetry(txUuid) {
  totalTransactionsScheduled++;
  let attempts = 0;
  let firstNode = 'unknown';
  let finalNode = 'unknown';
  let isReplay = false;
  let success = false;
  let lastError = null;
  let httpCode = 0;

  const startTime = Date.now();
  const payload = JSON.stringify({
    account_id: `ACC-${1000 + Math.floor(Math.random() * 9000)}`,
    amount: parseFloat((Math.random() * 500 + 10).toFixed(2)),
    currency: 'KES',
    tx_type: 'DEBIT',
    idempotency_key: txUuid,
  });

  while (attempts <= MAX_RETRIES && !success) {
    attempts++;
    totalRawAttempts++;
    secAttempts++;
    if (attempts > 1) {
      totalRetryAttempts++;
      secRetries++;
    }

    const attemptStart = Date.now();

    try {
      const response = await httpClient.request({
        path: targetPath,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Idempotency-Key': txUuid,
          'User-Agent': 'CarrierGrade-LoadTester/1.0',
        },
        body: payload,
        headersTimeout: TIMEOUT_MS,
        bodyTimeout: TIMEOUT_MS,
      });

      const bodyText = await response.body.text();
      httpCode = response.statusCode;
      const lbNode = response.headers['x-lb-node'] || 'unknown';

      if (attempts === 1) {
        firstNode = lbNode;
        if (!initialNodeObserved && lbNode !== 'unknown') {
          initialNodeObserved = lbNode;
        }
      }
      finalNode = lbNode;

      // Track LB node distribution
      secLbNodes[lbNode] = (secLbNodes[lbNode] || 0) + 1;

      // Check for failover recovery window
      if (firstFailTimestamp && !firstSuccessOtherNodeTimestamp) {
        if (initialNodeObserved && lbNode !== initialNodeObserved && lbNode !== 'unknown') {
          firstSuccessOtherNodeTimestamp = Date.now();
          failoverDetectedNode = lbNode;
        }
      }

      if (httpCode === 201 || httpCode === 200) {
        success = true;
        totalConfirmedSuccess++;
        secSuccesses++;

        try {
          const parsed = JSON.parse(bodyText);
          isReplay = parsed.is_replay === true;
        } catch (_) {}

        const elapsedMs = Date.now() - startTime;
        recordLatency(elapsedMs);

        // Record confirmed UUID for PostgreSQL reconciliation
        uuidsStream.write(`${txUuid}\n`);

        // Record CSV line
        csvStream.write(`${txUuid},COMMITTED,${httpCode},${attempts},${elapsedMs},${firstNode},${finalNode},${isReplay},${new Date().toISOString()}\n`);
        return;
      } else {
        // Unexpected HTTP status (e.g. 502/503 from dying node)
        throw new Error(`HTTP ${httpCode}: ${bodyText}`);
      }
    } catch (err) {
      lastError = err;
      secFails++;

      if (!firstFailTimestamp) {
        firstFailTimestamp = Date.now();
      }

      if (attempts <= MAX_RETRIES) {
        // Small jittered backoff before re-attempting with the EXACT same idempotency key
        const backoff = RETRY_BACKOFF_MS * attempts + Math.floor(Math.random() * 20);
        await new Promise((r) => setTimeout(r, backoff));
      }
    }
  }

  // If all retries exhausted
  totalPermanentFailures++;
  const elapsedMs = Date.now() - startTime;
  recordLatency(elapsedMs);
  csvStream.write(`${txUuid},FAILED,${httpCode},${attempts},${elapsedMs},${firstNode},${finalNode},false,${new Date().toISOString()}\n`);
}

// ------------------------------------------------------------------------------
// 4. Rate-Controlled Token Bucket Dispatcher
// ------------------------------------------------------------------------------
async function startLoadTest() {
  console.log('======================================================================');
  console.log('>> CARRIER-GRADE FAILOVER LOAD TEST GENERATOR');
  console.log(`>> Target:           ${TARGET_URL}`);
  console.log(`>> Rate:             ${TARGET_RATE} req/s`);
  console.log(`>> Duration:         ${DURATION_SEC} seconds`);
  console.log(`>> Per-Req Timeout:  ${TIMEOUT_MS} ms`);
  console.log(`>> Max Retries:      ${MAX_RETRIES} (Idempotency Key preserved)`);
  console.log(`>> CSV Output:       ${CSV_FILE}`);
  console.log('======================================================================');
  console.log('SEC | ATTEMPT | SUCCESS | RETRIES | FAIL-RAW | P50 (ms) | P95 (ms) | P99 (ms) | LB DISTRIBUTION');
  console.log('----+---------+---------+---------+----------+----------+----------+----------+-----------------');

  let secondCounter = 0;
  const testStartTime = Date.now();

  // Sliding window reporting interval (1 second)
  const reportInterval = setInterval(() => {
    secondCounter++;
    const p = calculatePercentiles(secLatencies);
    const lbDist = Object.entries(secLbNodes)
      .map(([node, count]) => `${node}:${count}`)
      .join(', ') || 'none';

    console.log(
      `${String(secondCounter).padStart(3, ' ')} | ` +
      `${String(secAttempts).padStart(7, ' ')} | ` +
      `${String(secSuccesses).padStart(7, ' ')} | ` +
      `${String(secRetries).padStart(7, ' ')} | ` +
      `${String(secFails).padStart(8, ' ')} | ` +
      `${String(p.p50).padStart(8, ' ')} | ` +
      `${String(p.p95).padStart(8, ' ')} | ` +
      `${String(p.p99).padStart(8, ' ')} | ` +
      `${lbDist}`
    );

    // Reset sliding metrics
    secAttempts = 0;
    secSuccesses = 0;
    secFails = 0;
    secRetries = 0;
    secLatencies = [];
    secLbNodes = {};

    if (secondCounter >= DURATION_SEC) {
      stopLoadTest();
    }
  }, 1000);

  // Precision dispatcher loop
  const intervalUs = 1000000 / TARGET_RATE; // microseconds between requests
  let nextDispatchTime = process.hrtime.bigint();

  const dispatchLoop = () => {
    if (!isRunning) return;

    const now = process.hrtime.bigint();
    while (now >= nextDispatchTime && isRunning) {
      const txUuid = randomUUID();
      executeTransactionWithRetry(txUuid).catch((err) => {
        console.error('Unhandled request failure:', err.message);
      });
      nextDispatchTime += BigInt(Math.floor(intervalUs * 1000));
    }

    if (isRunning) {
      setImmediate(dispatchLoop);
    }
  };

  dispatchLoop();

  async function stopLoadTest() {
    isRunning = false;
    clearInterval(reportInterval);

    console.log('----------------------------------------------------------------------');
    console.log('>> In-flight connection drainage in progress (waiting 3s)...');
    await new Promise((r) => setTimeout(r, 3000));

    await httpClient.close();
    csvStream.end();
    uuidsStream.end();

    printSummary(testStartTime);
  }
}

// ------------------------------------------------------------------------------
// 5. Final Reporting & Failover Window Analysis
// ------------------------------------------------------------------------------
function printSummary(testStartTime) {
  const durationTotalSec = ((Date.now() - testStartTime) / 1000).toFixed(1);
  const percentiles = calculatePercentiles(allLatencies);

  let failoverWindowMs = 0;
  if (firstFailTimestamp && firstSuccessOtherNodeTimestamp) {
    failoverWindowMs = firstSuccessOtherNodeTimestamp - firstFailTimestamp;
  }

  const summary = {
    target_url: TARGET_URL,
    configured_rate_rps: TARGET_RATE,
    duration_seconds: parseFloat(durationTotalSec),
    total_transactions_scheduled: totalTransactionsScheduled,
    total_confirmed_success: totalConfirmedSuccess,
    total_permanent_failures: totalPermanentFailures,
    raw_attempts_total: totalRawAttempts,
    retry_attempts_total: totalRetryAttempts,
    success_rate_percent: totalTransactionsScheduled > 0
      ? ((totalConfirmedSuccess / totalTransactionsScheduled) * 100).toFixed(2)
      : '0.00',
    latencies_ms: percentiles,
    failover_metrics: {
      initial_active_node: initialNodeObserved,
      failover_detected_node: failoverDetectedNode,
      first_failure_time: firstFailTimestamp ? new Date(firstFailTimestamp).toISOString() : null,
      recovery_time: firstSuccessOtherNodeTimestamp ? new Date(firstSuccessOtherNodeTimestamp).toISOString() : null,
      measured_failover_window_ms: failoverWindowMs,
      measured_failover_window_seconds: (failoverWindowMs / 1000).toFixed(3),
    },
    csv_file: CSV_FILE,
    confirmed_uuids_file: UUIDS_FILE,
  };

  fs.writeFileSync(SUMMARY_FILE, JSON.stringify(summary, null, 2));

  console.log('\n======================================================================');
  console.log('>> FAILOVER LOAD TEST EXECUTION SUMMARY');
  console.log('======================================================================');
  console.log(`Transactions Scheduled:      ${totalTransactionsScheduled}`);
  console.log(`Confirmed Committed:         ${totalConfirmedSuccess} (Target: Exactly Once)`);
  console.log(`Permanent Failures:          ${totalPermanentFailures}`);
  console.log(`Total Retried Attempts:      ${totalRetryAttempts}`);
  console.log(`Latency p50 / p95 / p99:     ${percentiles.p50}ms / ${percentiles.p95}ms / ${percentiles.p99}ms`);
  console.log('----------------------------------------------------------------------');

  if (failoverWindowMs > 0) {
    console.log(`>> FAILOVER EVENT DETECTED!`);
    console.log(`>> First Connection Failure: ${new Date(firstFailTimestamp).toISOString()}`);
    console.log(`>> Recovery via Standby:     ${new Date(firstSuccessOtherNodeTimestamp).toISOString()} (${failoverDetectedNode})`);
    console.log(`>> MEASURED FAILOVER WINDOW: ${failoverWindowMs} ms (${(failoverWindowMs / 1000).toFixed(3)} s)`);
    if (failoverWindowMs <= 2000) {
      console.log(`>> [TARGET ACHIEVED] Failover duration is STRICTLY UNDER 2.0 SECONDS!`);
    } else {
      console.log(`>> [WARNING] Failover duration exceeded 2.0s target.`);
    }
  } else {
    console.log(`>> No failover event detected during this run (clean steady-state).`);
  }

  console.log('======================================================================');
  console.log(`Full CSV Log:    ${CSV_FILE}`);
  console.log(`JSON Summary:    ${SUMMARY_FILE}`);
  console.log(`Confirmed UUIDs: ${UUIDS_FILE}`);
  console.log('======================================================================');
}

startLoadTest().catch((err) => {
  console.error('Fatal load test error:', err);
  process.exit(1);
});
