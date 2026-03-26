const http = require('http');

const server = http.createServer((req, res) => {
  const version = process.env.VERSION || '1';
  
  console.log(`[v${version}] Request received: ${req.url}`);
  
  res.writeHead(200, {'Content-Type': 'text/plain'});
  res.end(`Hello World v${version}!\n`);
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received, closing server gracefully...');
  // Close idle keep-alive connections immediately so nginx doesn't reuse
  // a stale connection and get a TCP reset (which causes HTTP 000 in clients).
  // Active connections finish naturally before server.close() resolves.
  server.closeIdleConnections();
  server.close(() => {
    console.log('All connections closed, exiting.');
    process.exit(0);
  });
});
