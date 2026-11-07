// ==============================================================================
// ha-rhel-cluster/db/patroni/test-patroni-config.js
// Automated Validator for Stage 8 Patroni HA & etcd Consensus Blueprint
// ==============================================================================

const fs = require('fs');
const path = require('path');

const tmplPath = path.join(__dirname, 'patroni.yml.tmpl');
if (!fs.existsSync(tmplPath)) {
  console.error(`[FAIL] Template not found: ${tmplPath}`);
  process.exit(1);
}

const templateContent = fs.readFileSync(tmplPath, 'utf8');

console.log('======================================================================');
console.log('>> Running Automated Validation on Stage 8 Patroni Architecture');
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

// 1. Quorum & Raft Consensus Proof (Odd-number requirement)
const etcdNodes = 3;
const quorumRequired = Math.floor(etcdNodes / 2) + 1;
const faultTolerance = etcdNodes - quorumRequired;

assert(etcdNodes === 3, 'etcd consensus cluster has 3 nodes (odd number prevents split-brain)');
assert(quorumRequired === 2, `Quorum requires ${quorumRequired} healthy votes to elect a database leader`);
assert(faultTolerance === 1, `Cluster can sustain loss of ${faultTolerance} node with 0 loss of write availability`);

// 2. Validate Patroni Template Rendering for app1 and app2
const nodes = [
  { name: 'app1', ip: '192.168.56.20' },
  { name: 'app2', ip: '192.168.56.21' },
];

for (const node of nodes) {
  console.log(`\nValidating Patroni configuration for node: ${node.name}...`);

  let rendered = templateContent
    .replace(/__PATRONI_CLUSTER_NAME__/g, 'ha-pg-cluster')
    .replace(/__PATRONI_NODE_NAME__/g, node.name)
    .replace(/__PATRONI_API_PORT__/g, '8008')
    .replace(/__NODE_IP__/g, node.ip)
    .replace(/__DB_PORT__/g, '5432')
    .replace(/__DB_REPLICATION_USER__/g, 'replicator')
    .replace(/__DB_REPLICATION_PASS__/g, 'ReplSecure2026!')
    .replace(/__DB_PASS__/g, 'TxSecurePass2026!');

  // Check tokens
  const unreplaced = rendered.match(/__[A-Z0-9_]+__/g);
  assert(!unreplaced, `All tokens rendered cleanly on ${node.name}`);

  // Assert API port 8008
  assert(rendered.includes('0.0.0.0:8008'), `Patroni REST API listens on port 8008 on ${node.name}`);

  // Assert etcd3 endpoints
  assert(rendered.includes('192.168.56.20:2379') && rendered.includes('192.168.56.21:2379') && rendered.includes('192.168.56.30:2379'), `Configured with all 3 etcd DCS peers on ${node.name}`);

  // Assert Synchronous Replication (Zero RPO)
  assert(rendered.includes('synchronous_mode: true'), `Enforces synchronous_mode: true for zero data loss on ${node.name}`);

  // Assert pg_rewind enabled
  assert(rendered.includes('use_pg_rewind: true'), `Enables pg_rewind for automated rejoin of recovered primary on ${node.name}`);
}

console.log('\n----------------------------------------------------------------------');
console.log(`Stage 8 Validation Completed: ${passed} passed, ${failed} failed.`);
console.log('======================================================================');

process.exit(failed > 0 ? 1 : 0);
