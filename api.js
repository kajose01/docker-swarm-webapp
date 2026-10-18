const http = require('http');
const fs = require('fs');
const os = require('os');
const { Pool } = require('pg');

const VERSION = process.env.APP_VERSION || 'dev';
const password = fs.readFileSync(process.env.DB_PASSWORD_FILE || '/run/secrets/db_password', 'utf8').trim();

const pool = new Pool({
  host: process.env.DB_HOST || 'db',
  user: process.env.DB_USER || 'app',
  password,
  database: process.env.DB_NAME || 'appdb',
  max: 5,
  connectionTimeoutMillis: 3000,
});
// Without this handler a dropped database connection would crash the process
pool.on('error', (e) => console.error('pool error:', e.message));

let ready = false;
async function ensure() {
  if (ready) return;
  await pool.query('CREATE TABLE IF NOT EXISTS counter (id INT PRIMARY KEY, n BIGINT NOT NULL)');
  await pool.query('INSERT INTO counter (id, n) VALUES (1, 0) ON CONFLICT DO NOTHING');
  ready = true;
}

const send = (res, code, body) => {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

http.createServer(async (req, res) => {
  if (req.url === '/health') return send(res, 200, { status: 'ok' });
  if (req.url === '/api/hit') {
    try {
      await ensure();
      const r = await pool.query('UPDATE counter SET n = n + 1 WHERE id = 1 RETURNING n');
      return send(res, 200, { count: Number(r.rows[0].n), api_host: os.hostname(), api_version: VERSION });
    } catch (e) {
      console.error(e.message);
      return send(res, 500, { error: 'database unavailable' });
    }
  }
  send(res, 404, { error: 'not found' });
}).listen(4000, () => console.log(`api ${VERSION} listening on 4000`));
