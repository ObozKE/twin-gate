// ==============================================================================
// ha-rhel-cluster/app/test-api.js
// Automated Unit & Integration Test Suite for Transaction API
// Runs standalone without external dependencies to verify endpoint contracts
// ==============================================================================

const http = require('http');
const { randomUUID } = require('crypto');

process.env.USE_MOCK_DB = 'true';
process.env.PORT = '3099';
process.env.BACKEND_NAME = 'api-replica-test';

const { server } = require('./server');

function makeRequest(options, postData = null) {
  return new Promise((resolve, reject) => {
    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(data); } catch (e) { json = data; }
        resolve({
          statusCode: res.statusCode,
          headers: res.headers,
          body: json,
        });
      });
    });
    req.on('error', reject);
    if (postData) {
      req.write(typeof postData === 'string' ? postData : JSON.stringify(postData));
    }
    req.end();
  });
}

async function runTests() {
  console.log('======================================================================');
  console.log('>> Running Automated Self-Tests on HA Transaction API Server');
  console.log('======================================================================');

  let passed = 0;
  let failed = 0;

  async function assertTest(name, fn) {
    try {
      await fn();
      console.log(`[PASS] ${name}`);
      passed++;
    } catch (err) {
      console.error(`[FAIL] ${name}: ${err.message}`);
      failed++;
    }
  }

  // Test 1: GET /health
  await assertTest('GET /health returns 200 UP', async () => {
    const res = await makeRequest({ host: '127.0.0.1', port: 3099, path: '/health', method: 'GET' });
    if (res.statusCode !== 200) throw new Error(`Expected status 200, got ${res.statusCode}`);
    if (res.body.status !== 'UP') throw new Error(`Expected status UP, got ${res.body.status}`);
  });

  // Test 2: GET /whoami and X-Backend header
  await assertTest('GET /whoami returns identity and X-Backend header', async () => {
    const res = await makeRequest({ host: '127.0.0.1', port: 3099, path: '/whoami', method: 'GET' });
    if (res.statusCode !== 200) throw new Error(`Expected status 200, got ${res.statusCode}`);
    if (res.headers['x-backend'] !== 'api-replica-test') {
      throw new Error(`Expected X-Backend api-replica-test, got ${res.headers['x-backend']}`);
    }
    if (res.body.backend !== 'api-replica-test') throw new Error('Body backend mismatch');
  });

  // Test 3: POST /transactions fresh insertion (HTTP 201)
  const txUuid = randomUUID();
  await assertTest('POST /transactions commits fresh transaction with HTTP 201', async () => {
    const payload = {
      account_id: 'ACC-SRE-LAB-1',
      amount: 4500.50,
      currency: 'KES',
      tx_type: 'DEBIT',
    };
    const res = await makeRequest({
      host: '127.0.0.1',
      port: 3099,
      path: '/transactions',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Idempotency-Key': txUuid,
      },
    }, payload);

    if (res.statusCode !== 201) throw new Error(`Expected 201, got ${res.statusCode}: ${JSON.stringify(res.body)}`);
    if (res.body.is_replay !== false) throw new Error('Expected is_replay=false');
    if (res.body.idempotency_key !== txUuid) throw new Error('UUID mismatch in returned transaction');
  });

  // Test 4: POST /transactions idempotent replay (HTTP 200 with is_replay: true)
  await assertTest('POST /transactions idempotent replay returns HTTP 200 with is_replay=true', async () => {
    const payload = {
      account_id: 'ACC-SRE-LAB-1',
      amount: 4500.50,
      currency: 'KES',
      tx_type: 'DEBIT',
    };
    const res = await makeRequest({
      host: '127.0.0.1',
      port: 3099,
      path: '/transactions',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Idempotency-Key': txUuid,
      },
    }, payload);

    if (res.statusCode !== 200) throw new Error(`Expected 200, got ${res.statusCode}`);
    if (res.body.is_replay !== true) throw new Error('Expected is_replay=true on replay');
    if (res.body.idempotency_key !== txUuid) throw new Error('UUID mismatch on replay');
  });

  // Test 5: GET /transactions/count reflects exactly 1 transaction
  await assertTest('GET /transactions/count reflects exactly 1 transaction stored', async () => {
    const res = await makeRequest({ host: '127.0.0.1', port: 3099, path: '/transactions/count', method: 'GET' });
    if (res.statusCode !== 200) throw new Error(`Expected 200, got ${res.statusCode}`);
    if (res.body.count !== 1) throw new Error(`Expected count=1, got ${res.body.count}`);
  });

  // Test 6: Invalid UUID rejected with HTTP 400
  await assertTest('POST /transactions rejects invalid UUID with HTTP 400', async () => {
    const res = await makeRequest({
      host: '127.0.0.1',
      port: 3099,
      path: '/transactions',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Idempotency-Key': 'not-a-valid-uuid',
      },
    }, { account_id: 'ACC-1', amount: 100 });

    if (res.statusCode !== 400) throw new Error(`Expected 400, got ${res.statusCode}`);
  });

  // Test 7: GET /metrics exposes Prometheus metrics
  await assertTest('GET /metrics exposes Prometheus metrics', async () => {
    const res = await makeRequest({ host: '127.0.0.1', port: 3099, path: '/metrics', method: 'GET' });
    if (res.statusCode !== 200) throw new Error(`Expected 200, got ${res.statusCode}`);
    if (typeof res.body !== 'string' || !res.body.includes('transactions_total')) {
      throw new Error('Prometheus metrics missing transactions_total');
    }
  });

  console.log('----------------------------------------------------------------------');
  console.log(`Test Execution Finished. Passed: ${passed}, Failed: ${failed}`);
  console.log('======================================================================');

  server.close(() => {
    process.exit(failed > 0 ? 1 : 0);
  });
}

runTests().catch((err) => {
  console.error('Fatal test error:', err);
  process.exit(1);
});
