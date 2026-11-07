// ==============================================================================
// ha-rhel-cluster/lb/haproxy/test-haproxy-template.js
// Automated Template and Configuration Validator for HAProxy
// ==============================================================================

const fs = require('fs');
const path = require('path');

const tmplPath = path.join(__dirname, 'haproxy.cfg.tmpl');
if (!fs.existsSync(tmplPath)) {
  console.error(`[FAIL] Template not found at: ${tmplPath}`);
  process.exit(1);
}

const templateContent = fs.readFileSync(tmplPath, 'utf8');

const testCases = [
  {
    name: 'lb1',
    nodeIp: '192.168.56.11',
    vip: '192.168.56.10',
    port: '8080',
    app1Ip: '192.168.56.20',
    appPort1: '8081',
    appPort2: '8082',
    statsPort: '8404',
    statsUser: 'admin',
    statsPass: 'SreLab2026!',
  },
  {
    name: 'lb2',
    nodeIp: '192.168.56.12',
    vip: '192.168.56.10',
    port: '8080',
    app1Ip: '192.168.56.20',
    appPort1: '8081',
    appPort2: '8082',
    statsPort: '8404',
    statsUser: 'admin',
    statsPass: 'SreLab2026!',
  },
];

console.log('======================================================================');
console.log('>> Running Automated Validation on HAProxy Configurations');
console.log('======================================================================');

let passed = 0;
let failed = 0;

function assert(condition, message) {
  if (condition) {
    console.log(`[PASS] ${message}`);
    passed++;
  } else {
    console.error(`[FAIL] ${message}`);
    failed++;
  }
}

for (const tc of testCases) {
  console.log(`\nValidating rendered configuration for node: ${tc.name}...`);

  let rendered = templateContent
    .replace(/__VIP__/g, tc.vip)
    .replace(/__VIP_PORT__/g, tc.port)
    .replace(/__NODE_IP__/g, tc.nodeIp)
    .replace(/__LB_NODE_NAME__/g, tc.name)
    .replace(/__APP1_IP__/g, tc.app1Ip)
    .replace(/__APP_PORT_1__/g, tc.appPort1)
    .replace(/__APP_PORT_2__/g, tc.appPort2)
    .replace(/__HAPROXY_STATS_PORT__/g, tc.statsPort)
    .replace(/__HAPROXY_STATS_USER__/g, tc.statsUser)
    .replace(/__HAPROXY_STATS_PASS__/g, tc.statsPass);

  // Assert no unreplaced tokens remain
  const unreplaced = rendered.match(/__[A-Z0-9_]+__/g);
  assert(!unreplaced, `All tokens rendered cleanly (found: ${unreplaced ? unreplaced.join(', ') : 'none'})`);

  // Assert VIP binding
  assert(rendered.includes(`bind ${tc.vip}:${tc.port} name vip`), `Binds to floating VIP (${tc.vip}:${tc.port})`);

  // Assert local node binding
  assert(rendered.includes(`bind ${tc.nodeIp}:${tc.port} name node_local`), `Binds to local node IP (${tc.nodeIp}:${tc.port})`);

  // Assert X-LB-Node header
  assert(rendered.includes(`http-response set-header X-LB-Node ${tc.name}`), `Injects X-LB-Node ${tc.name} header`);

  // Assert roundrobin balancing
  assert(rendered.includes('balance     roundrobin'), 'Configured with roundrobin load balancing');

  // Assert health check
  assert(rendered.includes('option httpchk GET /health'), 'Active health check configured on GET /health');
  assert(rendered.includes('http-check expect status 200'), 'Expects HTTP 200 for health checks');

  // Assert backend servers
  assert(rendered.includes(`server app1_replica1 ${tc.app1Ip}:${tc.appPort1} check`), `Proxies to backend replica 1 (${tc.app1Ip}:${tc.appPort1})`);
  assert(rendered.includes(`server app1_replica2 ${tc.app1Ip}:${tc.appPort2} check`), `Proxies to backend replica 2 (${tc.app1Ip}:${tc.appPort2})`);

  // Assert Prometheus metrics
  assert(rendered.includes('http-request use-service prometheus-exporter if { path /metrics }'), 'Prometheus exporter service active on /metrics');
}

console.log('\n----------------------------------------------------------------------');
console.log(`Validation Completed: ${passed} passed, ${failed} failed.`);
console.log('======================================================================');

process.exit(failed > 0 ? 1 : 0);
