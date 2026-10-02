// Lokaler Test-Server: liefert index.html aus, leitet /rest/v1 an PostgREST weiter
// und spielt eine Minimal-Version der Supabase-Anmeldung (/auth/v1) nach.
// Nur für automatisierte Tests - hat mit dem echten Betrieb nichts zu tun.
const http = require('http'), fs = require('fs'), path = require('path');
const jwt = require('/var/tmp/lp-e2e/node_modules/jsonwebtoken');
const ROOT = path.resolve(__dirname, '../..');
const SECRET = 'lokales-test-geheimnis-mindestens-32-zeichen';
const USER = { id: '11111111-1111-1111-1111-111111111111', email: 'test@lager.local', aud: 'authenticated', role: 'authenticated' };
// Verzögerung für REST-Aufrufe (simuliert langsames Lager-WLAN), per /__delay?ms=…
let delayMs = 0;
function token() {
  const exp = Math.floor(Date.now() / 1000) + 3600 * 24;
  return jwt.sign({ sub: USER.id, email: USER.email, role: 'authenticated', aud: 'authenticated', exp }, SECRET);
}
const send = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*' }); res.end(JSON.stringify(obj)); };
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (req.method === 'OPTIONS') {
    res.writeHead(204, { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' });
    return res.end();
  }
  if (u.pathname === '/__delay') { delayMs = +u.searchParams.get('ms') || 0; return send(res, 200, { delayMs }); }
  if (u.pathname.startsWith('/auth/v1/')) {
    const t = token(), now = Math.floor(Date.now() / 1000);
    if (u.pathname === '/auth/v1/token') return send(res, 200, { access_token: t, token_type: 'bearer', expires_in: 86400, expires_at: now + 86400, refresh_token: 'r', user: USER });
    if (u.pathname === '/auth/v1/user') return send(res, 200, USER);
    if (u.pathname === '/auth/v1/logout') { res.writeHead(204, { 'access-control-allow-origin': '*' }); return res.end(); }
    return send(res, 404, { msg: 'nicht nachgebildet' });
  }
  if (u.pathname.startsWith('/rest/v1')) {
    const ziel = u.pathname.slice('/rest/v1'.length) || '/';
    const headers = { ...req.headers }; delete headers.host;
    // anon-Key ohne Anmeldung: PostgREST braucht dann gar keinen Token
    if (headers.authorization && !headers.authorization.includes('.')) delete headers.authorization;
    if (headers.authorization && headers.apikey && headers.authorization === 'Bearer ' + headers.apikey) delete headers.authorization;
    const weiter = () => {
      const p = http.request({ host: '127.0.0.1', port: 54330, path: ziel + u.search, method: req.method, headers }, r => {
        res.writeHead(r.statusCode, { ...r.headers, 'access-control-allow-origin': '*', 'access-control-expose-headers': '*' });
        r.pipe(res);
      });
      p.on('error', e => send(res, 502, { message: e.message }));
      req.pipe(p);
    };
    return delayMs ? setTimeout(weiter, delayMs) : weiter();
  }
  const datei = path.join(ROOT, decodeURIComponent(u.pathname === '/' ? '/index.html' : u.pathname));
  if (!datei.startsWith(ROOT) || !fs.existsSync(datei)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': datei.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream' });
  fs.createReadStream(datei).pipe(res);
}).listen(54331);
