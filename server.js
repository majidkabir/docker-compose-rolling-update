const http = require('http');

const server = http.createServer((req, res) => {
  console.log('Request received:', req.url);
  res.writeHead(200, {'Content-Type': 'text/plain'});
  res.end('Hello World 1!\n');
});

server.listen(3000, () => {
  console.log(`Server running on port 3000`);
});
