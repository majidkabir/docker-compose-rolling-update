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
