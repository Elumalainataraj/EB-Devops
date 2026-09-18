'use strict';

const http = require('http');
const os = require('os');

const APP_NAME = process.env.APP_NAME || 'unknown-app';
const VERSION = process.env.VERSION || '0.0.0';
const PORT = process.env.PORT || 3000;

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer((req, res) => {
  if (req.method !== 'GET') {
    sendJson(res, 405, { error: 'method not allowed' });
    return;
  }

  if (req.url === '/healthz') {
    sendJson(res, 200, { status: 'ok' });
    return;
  }

  if (req.url === '/') {
    sendJson(res, 200, {
      app: APP_NAME,
      version: VERSION,
      pod: os.hostname(),
    });
    return;
  }

  sendJson(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`[${APP_NAME}] v${VERSION} listening on port ${PORT}`);
});

// Graceful shutdown — matters when Kubernetes sends SIGTERM during rollouts.
process.on('SIGTERM', () => {
  console.log('SIGTERM received, closing server');
  server.close(() => process.exit(0));
});
