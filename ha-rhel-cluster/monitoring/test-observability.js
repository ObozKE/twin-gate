// ==============================================================================
// ha-rhel-cluster/monitoring/test-observability.js
// Automated Validator for Observability Stack Configurations
// Verifies Prometheus configs, Alert Rules, Grafana 1080p Dashboard, and Exporter
// ==============================================================================

const fs = require('fs');
const path = require('path');

console.log('======================================================================');
console.log('>> Running Automated Validation on Observability Stack (Stage 6)');
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

// ------------------------------------------------------------------------------
// 1. Validate Prometheus Configuration
// ------------------------------------------------------------------------------
console.log('\n[TEST 1/4] Validating Prometheus configuration (prometheus.yml)...');
const promPath = path.join(__dirname, 'prometheus', 'prometheus.yml');
assert(fs.existsSync(promPath), 'prometheus.yml exists');

const promContent = fs.readFileSync(promPath, 'utf8');
assert(promContent.includes('scrape_interval:     1s') || promContent.includes('scrape_interval: 1s'), 'Global scrape interval configured to 1s resolution');
assert(promContent.includes('job_name: "keepalived"'), 'Contains keepalived scrape job');
assert(promContent.includes('job_name: "haproxy"'), 'Contains haproxy scrape job');
assert(promContent.includes('job_name: "app_api"'), 'Contains app_api scrape job');
assert(promContent.includes('job_name: "node_exporter"'), 'Contains node_exporter scrape job');
assert(promContent.includes('192.168.56.11:9650') && promContent.includes('192.168.56.12:9650'), 'Scrapes Keepalived on both lb1 and lb2');
assert(promContent.includes('192.168.56.11:8404') && promContent.includes('192.168.56.12:8404'), 'Scrapes HAProxy metrics on both lb1 and lb2');
assert(promContent.includes('192.168.56.20:8081') && promContent.includes('192.168.56.20:8082'), 'Scrapes both API replicas on app1');

// ------------------------------------------------------------------------------
// 2. Validate Prometheus Alert Rules
// ------------------------------------------------------------------------------
console.log('\n[TEST 2/4] Validating Prometheus Alert Rules (alert.rules.yml)...');
const alertPath = path.join(__dirname, 'prometheus', 'alert.rules.yml');
assert(fs.existsSync(alertPath), 'alert.rules.yml exists');

const alertContent = fs.readFileSync(alertPath, 'utf8');
assert(alertContent.includes('alert: VRRPSplitBrain'), 'Alert rule VRRPSplitBrain defined');
assert(alertContent.includes('sum(keepalived_vrrp_is_master) > 1'), 'Split-brain rule detects multiple simultaneous masters');
assert(alertContent.includes('alert: VRRPNoMaster'), 'Alert rule VRRPNoMaster defined');
assert(alertContent.includes('alert: VRRPStateChange'), 'Alert rule VRRPStateChange defined');
assert(alertContent.includes('alert: HAProxyBackendServerDown'), 'Alert rule HAProxyBackendServerDown defined');

// ------------------------------------------------------------------------------
// 3. Validate Grafana Dashboard JSON
// ------------------------------------------------------------------------------
console.log('\n[TEST 3/4] Validating Grafana 1080p Dashboard JSON (ha-cluster-overview.json)...');
const dashPath = path.join(__dirname, 'grafana', 'dashboards', 'ha-cluster-overview.json');
assert(fs.existsSync(dashPath), 'ha-cluster-overview.json exists');

let dashboard = null;
try {
  dashboard = JSON.parse(fs.readFileSync(dashPath, 'utf8'));
  assert(true, 'Dashboard JSON is valid and parses cleanly');
} catch (e) {
  assert(false, `Dashboard JSON parse error: ${e.message}`);
}

if (dashboard) {
  assert(dashboard.refresh === '1s', 'Dashboard auto-refreshes every 1s for live failover observation');
  assert(dashboard.panels.length >= 8, `Dashboard contains comprehensive panel grid (${dashboard.panels.length} panels)`);

  const panelTitles = dashboard.panels.map((p) => p.title);
  assert(panelTitles.some((t) => t.includes('VIP Owner') || t.includes('MASTER')), 'Panel 1: VIP Owner / Active MASTER stat panel exists');
  assert(panelTitles.some((t) => t.includes('Throughput')), 'Panel 2: Request throughput panel exists');
  assert(panelTitles.some((t) => t.includes('Latency')), 'Panel 3: Transaction latency percentiles panel exists');
  assert(panelTitles.some((t) => t.includes('HAProxy Ingress Traffic Distribution')), 'Panel 4: lb1 vs lb2 ingress distribution panel exists');
  assert(panelTitles.some((t) => t.includes('Status Code')), 'Panel 5: HTTP status & error rate panel exists');
  assert(panelTitles.some((t) => t.includes('Backend') || t.includes('Microservice')), 'Panel 6: Backend server health timeline exists');
  assert(panelTitles.some((t) => t.includes('CPU')), 'Panel 7: Node CPU utilization panel exists');
  assert(panelTitles.some((t) => t.includes('Memory')), 'Panel 8: Node Memory usage panel exists');

  assert(dashboard.annotations && dashboard.annotations.list.length > 0, 'Grafana VRRP failover annotation query configured');
}

// ------------------------------------------------------------------------------
// 4. Validate Keepalived Exporter Code
// ------------------------------------------------------------------------------
console.log('\n[TEST 4/4] Validating Keepalived Exporter (keepalived-exporter.js)...');
const exporterPath = path.join(__dirname, 'keepalived-exporter', 'keepalived-exporter.js');
assert(fs.existsSync(exporterPath), 'keepalived-exporter.js exists');

const exporterContent = fs.readFileSync(exporterPath, 'utf8');
assert(exporterContent.includes('keepalived_vrrp_state'), 'Exposes keepalived_vrrp_state metric');
assert(exporterContent.includes('keepalived_vrrp_is_master'), 'Exposes keepalived_vrrp_is_master metric');
assert(exporterContent.includes('keepalived_vrrp_priority'), 'Exposes keepalived_vrrp_priority metric');

console.log('\n----------------------------------------------------------------------');
console.log(`Observability Stack Validation Completed: ${passed} passed, ${failed} failed.`);
console.log('======================================================================');

process.exit(failed > 0 ? 1 : 0);
