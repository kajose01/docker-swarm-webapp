const http = require('http');
const os = require('os');

const VERSION = process.env.APP_VERSION || 'dev';
const API = process.env.API_URL || 'http://api:4000';

const send = (res, code, body) => {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

http.createServer((req, res) => {
  if (req.url === '/health') return send(res, 200, { status: 'ok' });
  if (req.url !== '/') return send(res, 404, { error: 'not found' });
  const call = http.get(`${API}/api/hit`, { timeout: 3000 }, (r) => {
    let d = '';
    r.on('data', (c) => (d += c));
    r.on('end', () => {
      let api = {};
      try { api = JSON.parse(d); } catch (_) {}
      send(res, r.statusCode === 200 ? 200 : 502,
        { web_host: os.hostname(), web_version: VERSION, api });
    });
  });
  call.on('timeout', () => call.destroy());
  call.on('error', () => send(res, 502, { web_host: os.hostname(), web_version: VERSION, error: 'api unreachable' }));
}).listen(3000, () => console.log(`web ${VERSION} listening on 3000`));
