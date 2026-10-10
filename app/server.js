const express = require('express');
const os = require('os');

const app = express();
app.use(express.json());

// Configuration from Environment Variables
const PORT = parseInt(process.env.PORT || '8080', 10);
const APP_ENV = (process.env.APP_ENV || 'blue').toLowerCase();
const APP_VERSION = process.env.APP_VERSION || 'v1.0.0';
let simulateFailure = (process.env.SIMULATE_FAILURE === 'true');

const HOSTNAME = os.hostname();
const START_TIME = new Date();

// Theme styling for HTML dashboard based on environment
const THEMES = {
  blue: {
    primary: '#2563eb',
    accent: '#3b82f6',
    badgeBg: '#eff6ff',
    badgeText: '#1d4ed8',
    glow: 'rgba(37, 99, 235, 0.25)',
    name: 'BLUE (Live)'
  },
  green: {
    primary: '#059669',
    accent: '#10b981',
    badgeBg: '#ecfdf5',
    badgeText: '#047857',
    glow: 'rgba(5, 150, 105, 0.25)',
    name: 'GREEN (Live)'
  },
  default: {
    primary: '#6366f1',
    accent: '#818cf8',
    badgeBg: '#eef2ff',
    badgeText: '#4338ca',
    glow: 'rgba(99, 102, 241, 0.25)',
    name: 'STANDBY'
  }
};

const currentTheme = THEMES[APP_ENV] || THEMES.default;

// 1. Health Check Endpoint (/health)
app.get('/health', (req, res) => {
  if (simulateFailure) {
    return res.status(500).json({
      status: 'DOWN',
      error: 'Simulated health check failure active',
      env: APP_ENV,
      version: APP_VERSION,
      hostname: HOSTNAME,
      timestamp: new Date().toISOString()
    });
  }

  res.status(200).json({
    status: 'UP',
    version: APP_VERSION,
    env: APP_ENV,
    hostname: HOSTNAME,
    uptimeSeconds: Math.floor(process.uptime()),
    timestamp: new Date().toISOString()
  });
});

// 2. Root Endpoint (/) - returns visual HTML dashboard or JSON depending on Accept header
app.get('/', (req, res) => {
  const acceptsJson = req.xhr || 
    (req.headers.accept && req.headers.accept.includes('application/json')) ||
    req.query.format === 'json';

  const payload = {
    status: simulateFailure ? 'DEGRADED' : 'UP',
    env: APP_ENV,
    version: APP_VERSION,
    hostname: HOSTNAME,
    uptimeSeconds: Math.floor(process.uptime()),
    clientIp: req.headers['x-forwarded-for'] || req.socket.remoteAddress,
    timestamp: new Date().toISOString()
  };

  if (acceptsJson) {
    return res.status(200).json(payload);
  }

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Zero-Downtime Release Engineering - ${currentTheme.name}</title>
  <style>
    :root {
      --primary: ${currentTheme.primary};
      --accent: ${currentTheme.accent};
      --glow: ${currentTheme.glow};
      --bg: #0f172a;
      --card-bg: rgba(30, 41, 59, 0.7);
      --card-border: rgba(255, 255, 255, 0.1);
      --text: #f8fafc;
      --text-muted: #94a3b8;
    }
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
    }
    body {
      background: radial-gradient(circle at 50% 0%, #1e293b 0%, var(--bg) 100%);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 24px;
    }
    .container {
      width: 100%;
      max-width: 680px;
      background: var(--card-bg);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border: 1px solid var(--card-border);
      border-radius: 20px;
      padding: 36px;
      box-shadow: 0 20px 40px rgba(0, 0, 0, 0.4), 0 0 50px var(--glow);
      text-align: center;
    }
    .badge-bar {
      display: flex;
      justify-content: center;
      gap: 12px;
      margin-bottom: 24px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 16px;
      border-radius: 9999px;
      font-size: 0.875rem;
      font-weight: 700;
      letter-spacing: 0.05em;
      text-transform: uppercase;
      background: ${currentTheme.badgeBg};
      color: ${currentTheme.badgeText};
      box-shadow: 0 2px 10px var(--glow);
    }
    .pulse-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: ${currentTheme.primary};
      animation: pulse 1.5s infinite;
    }
    @keyframes pulse {
      0% { transform: scale(0.95); box-shadow: 0 0 0 0 ${currentTheme.glow}; }
      70% { transform: scale(1.1); box-shadow: 0 0 0 8px rgba(0, 0, 0, 0); }
      100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(0, 0, 0, 0); }
    }
    h1 {
      font-size: 2rem;
      font-weight: 800;
      margin-bottom: 8px;
      background: linear-gradient(135deg, #ffffff 0%, #cbd5e1 100%);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .subtitle {
      color: var(--text-muted);
      font-size: 0.95rem;
      margin-bottom: 32px;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 16px;
      margin-bottom: 32px;
      text-align: left;
    }
    .card {
      background: rgba(15, 23, 42, 0.6);
      border: 1px solid rgba(255, 255, 255, 0.05);
      border-radius: 12px;
      padding: 16px 20px;
    }
    .card-label {
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--text-muted);
      margin-bottom: 4px;
    }
    .card-value {
      font-size: 1.15rem;
      font-weight: 600;
      color: #ffffff;
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
    }
    .footer {
      border-top: 1px solid rgba(255, 255, 255, 0.08);
      padding-top: 20px;
      font-size: 0.85rem;
      color: var(--text-muted);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .status-up {
      color: #34d399;
      font-weight: 600;
    }
    .status-down {
      color: #f87171;
      font-weight: 600;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="badge-bar">
      <div class="badge">
        <span class="pulse-dot"></span>
        <span>${APP_ENV.toUpperCase()} ENVIRONMENT</span>
      </div>
      <div class="badge" style="background: rgba(255,255,255,0.1); color: #f8fafc;">
        <span>${APP_VERSION}</span>
      </div>
    </div>
    <h1>Zero-Downtime Release</h1>
    <p class="subtitle">Automated Nginx Reverse Proxy with Docker Compose Blue-Green Deployment</p>

    <div class="grid">
      <div class="card">
        <div class="card-label">Active Environment</div>
        <div class="card-value" style="color: ${currentTheme.accent};">${APP_ENV.toUpperCase()}</div>
      </div>
      <div class="card">
        <div class="card-label">Release Version</div>
        <div class="card-value">${APP_VERSION}</div>
      </div>
      <div class="card">
        <div class="card-label">Container Hostname</div>
        <div class="card-value">${HOSTNAME}</div>
      </div>
      <div class="card">
        <div class="card-label">System Uptime</div>
        <div class="card-value">${Math.floor(process.uptime())}s</div>
      </div>
    </div>

    <div class="footer">
      <div>Status: <span class="${simulateFailure ? 'status-down' : 'status-up'}">${simulateFailure ? 'DEGRADED (Simulated)' : 'HEALTHY (HTTP 200)'}</span></div>
      <div>Proxy Port: ${PORT}</div>
    </div>
  </div>
</body>
</html>`;

  res.setHeader('Content-Type', 'text/html');
  res.send(html);
});

// 3. Chaos Engineering / Failure Simulation Endpoints
app.all('/chaos/fail', (req, res) => {
  simulateFailure = true;
  res.json({ message: 'Failure simulation enabled on ' + APP_ENV, simulateFailure: true });
});

app.all('/chaos/recover', (req, res) => {
  simulateFailure = false;
  res.json({ message: 'Failure simulation disabled on ' + APP_ENV, simulateFailure: false });
});

// Start Server
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`[${APP_ENV.toUpperCase()}] Server running on port ${PORT} (Version: ${APP_VERSION}, Hostname: ${HOSTNAME})`);
  console.log(`[${APP_ENV.toUpperCase()}] Health check endpoint available at http://0.0.0.0:${PORT}/health`);
});

// Graceful Shutdown Handling for Zero-Downtime Swaps
function gracefulShutdown(signal) {
  console.log(`[${APP_ENV.toUpperCase()}] Received ${signal}. Starting graceful shutdown...`);
  server.close(() => {
    console.log(`[${APP_ENV.toUpperCase()}] Closed all active HTTP connections. Process terminating.`);
    process.exit(0);
  });

  // Force close after 10 seconds if connections are stuck
  setTimeout(() => {
    console.error(`[${APP_ENV.toUpperCase()}] Forcing immediate shutdown after timeout.`);
    process.exit(1);
  }, 10000).unref();
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
