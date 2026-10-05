// Gemeinsame Hilfen für die Browser-Tests (siehe tests/README.md).
const { chromium } = require('playwright');
const { execSync } = require('child_process');
const path = require('path');

const BASE = 'http://localhost:54331';
const NM = '/var/tmp/lp-e2e/node_modules/';
const CDN = {
  'supabase-js': NM + '@supabase/supabase-js/dist/umd/supabase.js',
  'papaparse': NM + 'papaparse/papaparse.min.js',
  'xlsx': NM + 'xlsx/dist/xlsx.full.min.js',
};
const sql = q => execSync(`psql -h /tmp -p 54329 -U postgres -d lp -Atc "${q.replace(/"/g, '\\"')}"`).toString().trim();
const reset = () => {
  sql('truncate buchungen, leermeldungen, bestaende, lagerplaetze, artikel, mengen_abweichungen restart identity cascade');
  execSync(`psql -h /tmp -p 54329 -U postgres -d lp -q -f ${path.join(__dirname, '../sql/01_testdaten.sql')}`);
};
const menge = (art, lp) => sql(`select coalesce((select menge from bestaende where artikelnummer='${art}' and lagerplatz='${lp}'),0)`);
const delay = ms => execSync(`curl -s "${BASE}/__delay?ms=${ms}"`);
const gleich = (ist, soll, was) => { if (String(ist) !== String(soll)) throw new Error(`${was}: erwartet ${soll}, ist ${ist}`); };
const scanne = async (page, feld, code) => { await page.focus(feld); await page.keyboard.type(code); await page.keyboard.press('Enter'); };

async function neueSeite(ctx, jsFehler) {
  const page = await ctx.newPage();
  page.on('pageerror', e => jsFehler.push(e.message));
  page.on('dialog', d => d.accept());
  await page.route(/cdn\.jsdelivr\.net/, r => {
    const key = Object.keys(CDN).find(k => r.request().url().includes(k));
    return key ? r.fulfill({ path: CDN[key], contentType: 'application/javascript', headers: { 'Access-Control-Allow-Origin': '*' } }) : r.abort();
  });
  await page.goto(BASE + '/index.html');
  // zweites Fenster im selben Browser ist schon verbunden und angemeldet
  await page.waitForSelector('#url:visible, #app:visible');
  if (await page.isVisible('#url')) {
    await page.fill('#url', BASE); await page.fill('#key', 'testkey');
    await page.click('text=Verbinden');
    await page.fill('#email', 'test@lager.local'); await page.fill('#pass', 'x');
    await page.click('button:has-text("Anmelden")');
  }
  await page.waitForSelector('#app', { state: 'visible' });
  await page.waitForSelector('.such-table');
  return page;
}

const stand = { ok: 0, fehler: 0 };
async function test(name, fn) {
  reset(); delay(0);
  const browser = await chromium.launch();
  const ctx = await browser.newContext();
  const jsFehler = [];
  let page;
  try {
    page = await neueSeite(ctx, jsFehler);
    await fn(page, ctx, () => neueSeite(ctx, jsFehler));
    if (jsFehler.length) throw new Error('JavaScript-Fehler: ' + jsFehler.join(' | '));
    console.log('✅', name); stand.ok++;
  } catch (e) {
    console.log('❌', name, '\n   ', e.message.split('\n')[0]); stand.fehler++;
    if (page) await page.screenshot({ path: '/var/tmp/lp-e2e/fehler-' + name.replace(/\W+/g, '_') + '.png' }).catch(() => {});
  } finally { await browser.close(); }
}
function ende() { console.log(`\n${stand.ok} bestanden, ${stand.fehler} fehlgeschlagen`); process.exit(stand.fehler ? 1 : 0); }

module.exports = { BASE, sql, reset, menge, delay, gleich, scanne, test, ende };
