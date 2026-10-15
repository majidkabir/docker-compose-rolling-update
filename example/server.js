const http = require('http');

const version = process.env.VERSION || '1';
const PORT = process.env.PORT || 3000;
// Must be shorter than stop_grace_period in docker-compose.yaml.
const SHUTDOWN_TIMEOUT_MS = Number(process.env.SHUTDOWN_TIMEOUT_MS) || 10000;

// Simulates a bad release that crashes on startup (see example/README.md).
if (process.env.BROKEN === '1') {
  console.error(`[v${version}] BROKEN=1 set, failing on startup`);
  process.exit(1);
}

const server = http.createServer((req, res) => {
  console.log(`[v${version}] Request received: ${req.url}`);

  res.writeHead(200, {'Content-Type': 'text/plain'});
  res.end(`Hello World v${version}!\n`);
});

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});

let shuttingDown = false;

function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`${signal} received, closing server gracefully...`);

  // Close idle keep-alive connections immediately so nginx doesn't reuse
  // a stale connection and get a TCP reset (which causes HTTP 000 in clients).
  // Active connections finish naturally before server.close() resolves.
  server.closeIdleConnections();
  server.close(() => {
    console.log('All connections closed, exiting.');
    process.exit(0);
  });

  // Don't let a hung connection block shutdown until Docker's SIGKILL.
  setTimeout(() => {
    console.log(`Still busy after ${SHUTDOWN_TIMEOUT_MS}ms, forcing exit.`);
    server.closeAllConnections();
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
