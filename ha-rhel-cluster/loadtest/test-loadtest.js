// ==============================================================================
// ha-rhel-cluster/loadtest/test-loadtest.js
// Automated Integration Test for Failover Load Generator & Reconciliation
// Simulates a catastrophic 1.1s failover and validates recovery & zero loss
// ==============================================================================

const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const MOCK_PORT = 3080;
const mockDb = new Map();

let serverState = 'lb1_active'; // 'lb1_active' -> 'outage' -> 'lb2_active'
let outageStartTime = null;

const server = http.createServer((req, res) => {
  if (req.url === '/transactions' && req.method === 'POST') {
    if (serverState === 'outage') {
      // Simulate hard failure / dropped connection
      req.socket.destroy();
      return;
    }

    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      const idempotencyKey = req.headers['idempotency-key'];
      const activeLb = serverState === 'lb1_active' ? 'lb1' : 'lb2';

      res.setHeader('Content-Type', 'application/json');
      res.setHeader('X-LB-Node', activeLb);

      if (mockDb.has(idempotencyKey)) {
        // Replay
        const existing = mockDb.get(idempotencyKey);
        res.statusCode = 200;
        res.end(JSON.stringify({ ...existing, is_replay: true, served_by: activeLb }));
      } else {
        // Fresh commit
        const newRecord = {
          id: mockDb.size + 1,
          idempotency_key: idempotencyKey,
          status: 'COMMITTED',
          backend_node: activeLb,
          created_at: new Date().toISOString(),
        };
        mockDb.set(idempotencyKey, newRecord);
        res.statusCode = 201;
        res.end(JSON.stringify({ ...newRecord, is_replay: false, served_by: activeLb }));
      }
    });
  } else {
    res.statusCode = 404;
    res.end();
  }
});

server.listen(MOCK_PORT, '127.0.0.1', () => {
  console.log(`[TEST-MOCK] Ingress cluster simulator listening on port ${MOCK_PORT}`);
  runTestSequence();
});

async function runTestSequence() {
  console.log('======================================================================');
  console.log('>> Running Automated End-to-End Failover Load Test Simulation');
  console.log('======================================================================');

  // Trigger failover timeline
  // At T = 2.5s: Kill lb1 (enter outage)
  setTimeout(() => {
    console.log('\n[SIMULATOR] *** INITIATING CATASTROPHIC FAILOVER: lb1 KILLED ***');
    serverState = 'outage';
    outageStartTime = Date.now();
  }, 2500);

  // At T = 3.6s (1.1s later): lb2 becomes MASTER
  setTimeout(() => {
    const outageDuration = Date.now() - outageStartTime;
    console.log(`\n[SIMULATOR] *** lb2 BECOMES MASTER (Outage duration: ${outageDuration}ms) ***\n`);
    serverState = 'lb2_active';
  }, 3600);

  // Run loadtest.js targeting simulator
  const loadtestProcess = spawn('node', [
    path.join(__dirname, 'loadtest.js'),
    '--url', `http://127.0.0.1:${MOCK_PORT}/transactions`,
    '--rate', '50',
    '--duration', '5',
    '--timeout', '400',
    '--retries', '5',
  ], { stdio: 'inherit' });

  loadtestProcess.on('exit', async (code) => {
    console.log(`\n[TEST-MOCK] loadtest.js finished with exit code ${code}`);

    // Export mock database to JSON file for reconciliation
    const mockDbDumpFile = path.join(__dirname, 'results', 'mock-db-dump.json');
    const dbDump = Array.from(mockDb.values());
    fs.writeFileSync(mockDbDumpFile, JSON.stringify(dbDump, null, 2));

    console.log('\n>> Executing reconciliation against database dump...');
    const reconcileProcess = spawn('node', [
      path.join(__dirname, 'reconcile.js'),
      '--mock-db', mockDbDumpFile,
    ], { stdio: 'inherit' });

    reconcileProcess.on('exit', (rCode) => {
      server.close(() => {
        if (code === 0 && rCode === 0) {
          console.log('\n======================================================================');
          console.log('[SUCCESS] AUTOMATED FAILOVER SIMULATION & RECONCILIATION PASSED!');
          console.log('======================================================================');
          process.exit(0);
        } else {
          console.error(`\n[FAIL] Simulation failed! Loadtest code: ${code}, Reconcile code: ${rCode}`);
          process.exit(1);
        }
      });
    });
  });
}
