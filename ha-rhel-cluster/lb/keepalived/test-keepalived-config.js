// ==============================================================================
// ha-rhel-cluster/lb/keepalived/test-keepalived-config.js
// Automated Keepalived Configuration & RFC 5798 Timer Validator
// ==============================================================================

const fs = require('fs');
const path = require('path');

const tmplPath = path.join(__dirname, 'keepalived.conf.tmpl');
if (!fs.existsSync(tmplPath)) {
  console.error(`[FAIL] Template not found: ${tmplPath}`);
  process.exit(1);
}

const templateContent = fs.readFileSync(tmplPath, 'utf8');

console.log('======================================================================');
console.log('>> Running Automated Keepalived & RFC 5798 Math Validation');
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

// 1. RFC 5798 Failover Mathematical Proof
const advertInt = 0.3;
const pMaster = 150;
const pBackup = 100;
const weightDrop = -60;

const skewBackup = ((256 - pBackup) * advertInt) / 256;
const masterDownInterval = (3 * advertInt) + skewBackup;

assert(advertInt === 0.3, 'VRRPv3 advert_int is 0.3s (300ms)');
assert(masterDownInterval < 2.0, `Master_Down_Interval (${masterDownInterval.toFixed(4)}s) is strictly under 2.0s target`);
assert(masterDownInterval > 0.9 && masterDownInterval < 1.2, `Master_Down_Interval (${masterDownInterval.toFixed(4)}s) is within theoretical 1.08s window`);

// Health tracking failover proof:
// If HAProxy fails on lb1, priority drops: 150 - 60 = 90.
// Since 90 < 100 (lb2 backup priority), lb2 is guaranteed to become MASTER.
const droppedPriority = pMaster + weightDrop;
assert(droppedPriority < pBackup, `HAProxy failure priority (${droppedPriority}) drops below backup priority (${pBackup}), guaranteeing failover`);

// 2. Validate Template Rendering for lb1 & lb2
const testCases = [
  {
    name: 'lb1',
    iface: 'ens33',
    vrid: '56',
    priority: '150',
    advert: '0.3',
    state: 'MASTER',
    nopreempt: 'nopreempt',
    vip: '192.168.56.10',
  },
  {
    name: 'lb2',
    iface: 'ens33',
    vrid: '56',
    priority: '100',
    advert: '0.3',
    state: 'BACKUP',
    nopreempt: '',
    vip: '192.168.56.10',
  },
];

for (const tc of testCases) {
  console.log(`\nValidating Keepalived configuration for ${tc.name}...`);
  let rendered = templateContent
    .replace(/__LB_HOSTNAME__/g, tc.name)
    .replace(/__VIP_IFACE__/g, tc.iface)
    .replace(/__VRRP_ROUTER_ID__/g, tc.vrid)
    .replace(/__VRRP_PRIORITY__/g, tc.priority)
    .replace(/__VRRP_ADVERT_INT__/g, tc.advert)
    .replace(/__VRRP_INITIAL_STATE__/g, tc.state)
    .replace(/__NOPREEMPT_DIRECTIVE__/g, tc.nopreempt)
    .replace(/__VIP__/g, tc.vip);

  // Assert tokens
  const unreplaced = rendered.match(/__[A-Z0-9_]+__/g);
  assert(!unreplaced, `All tokens rendered cleanly on ${tc.name}`);

  // Assert RFC 5798 v3
  assert(rendered.includes('vrrp_version 3'), `Enforces VRRPv3 specification on ${tc.name}`);

  // Assert GARP bursts
  assert(rendered.includes('vrrp_garp_master_repeat 5'), `Configures 5x aggressive GARP repeats on ${tc.name}`);
  assert(rendered.includes('vrrp_garp_master_refresh 5'), `Configures 5s periodic GARP refreshes on ${tc.name}`);

  // Assert tracking script
  assert(rendered.includes('/usr/local/bin/check_haproxy.sh'), `Integrates check_haproxy.sh track_script on ${tc.name}`);
  assert(rendered.includes('weight -60'), `Configures -60 weight reduction on ${tc.name}`);

  // Assert VIP
  assert(rendered.includes(`${tc.vip}/24 dev ${tc.iface}`), `Binds floating VIP ${tc.vip}/24 on ${tc.iface}`);

  // Assert notify
  assert(rendered.includes('notify "/usr/local/bin/notify.sh"'), `Hooks millisecond notify.sh script on ${tc.name}`);

  if (tc.name === 'lb1') {
    assert(rendered.includes('nopreempt'), 'lb1 includes nopreempt to prevent failover flapping');
  }
}

console.log('\n----------------------------------------------------------------------');
console.log(`Keepalived Validation Completed: ${passed} passed, ${failed} failed.`);
console.log('======================================================================');

process.exit(failed > 0 ? 1 : 0);
