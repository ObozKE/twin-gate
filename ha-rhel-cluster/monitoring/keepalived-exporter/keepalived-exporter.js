// ==============================================================================
// ha-rhel-cluster/monitoring/keepalived-exporter/keepalived-exporter.js
// Lightweight Prometheus Exporter for Keepalived VRRP State & VIP Ownership
// Listens on port 9650 and exports metrics in Prometheus exposition format
// ==============================================================================

const http = require('http');
const fs = require('fs');
const { execSync } = require('child_process');
const os = require('os');

const PORT = parseInt(process.env.PORT || '9650', 10);
const STATE_FILE = process.env.STATE_FILE || '/var/run/keepalived-state.json';
const VIP = process.env.VIP || '192.168.56.10';
const NODE_NAME = os.hostname().split('.')[0];

function checkVipAssigned() {
  try {
    const output = execSync('ip -4 -br addr show', { encoding: 'utf8', timeout: 1000 });
    return output.includes(VIP);
  } catch (_) {
    return false;
  }
}

function getVrrpState() {
  let state = 'UNKNOWN';
  let priority = 0;
  let isMaster = false;

  // 1. Check state file from notify.sh
  if (fs.existsSync(STATE_FILE)) {
    try {
      const data = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
      state = data.state || 'UNKNOWN';
      priority = data.priority || 0;
      isMaster = data.is_master === true;
    } catch (_) {}
  }

  // 2. Corroborate with actual kernel interface IP assignment
  const hasVip = checkVipAssigned();
  if (hasVip) {
    state = 'MASTER';
    isMaster = true;
  } else if (state === 'MASTER' && !hasVip) {
    state = 'BACKUP';
    isMaster = false;
  }

  return { state, priority, isMaster };
}

const server = http.createServer((req, res) => {
  if (req.url === '/metrics' && req.method === 'GET') {
    const { state, priority, isMaster } = getVrrpState();

    const metrics = [
      '# HELP keepalived_vrrp_state Current VRRP state (1=active state, 0=inactive)',
      '# TYPE keepalived_vrrp_state gauge',
      `keepalived_vrrp_state{node="${NODE_NAME}",instance="VI_1",state="MASTER"} ${isMaster ? 1 : 0}`,
      `keepalived_vrrp_state{node="${NODE_NAME}",instance="VI_1",state="BACKUP"} ${!isMaster ? 1 : 0}`,
      `keepalived_vrrp_state{node="${NODE_NAME}",instance="VI_1",state="FAULT"} ${state === 'FAULT' ? 1 : 0}`,
      '',
      '# HELP keepalived_vrrp_is_master Whether this node currently owns the floating VIP (1=true, 0=false)',
      '# TYPE keepalived_vrrp_is_master gauge',
      `keepalived_vrrp_is_master{node="${NODE_NAME}"} ${isMaster ? 1 : 0}`,
      '',
      '# HELP keepalived_vrrp_priority Configured VRRP priority',
      '# TYPE keepalived_vrrp_priority gauge',
      `keepalived_vrrp_priority{node="${NODE_NAME}",instance="VI_1"} ${priority || (isMaster ? 150 : 100)}`,
      '',
    ].join('\n');

    res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4; charset=utf-8' });
    res.end(metrics);
  } else if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'UP', node: NODE_NAME }));
  } else {
    res.writeHead(404);
    res.end();
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[keepalived-exporter] Listening on port ${PORT} for node: ${NODE_NAME}`);
});
