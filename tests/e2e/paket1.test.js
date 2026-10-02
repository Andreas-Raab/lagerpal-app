// Browser-Tests für Paket 1 (Bedienung im Lager). Voraussetzung: tests/e2e/start.sh
// läuft. Aufruf: NODE_PATH=$(npm root -g) node tests/e2e/paket1.test.js
// Jeder Test startet mit frisch geladenen Testdaten (tests/sql/01_testdaten.sql).
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
  sql('truncate buchungen, leermeldungen, bestaende, lagerplaetze, artikel restart identity cascade');
  execSync(`psql -h /tmp -p 54329 -U postgres -d lp -q -f ${path.join(__dirname, '../sql/01_testdaten.sql')}`);
};
const menge = (art, lp) => sql(`select coalesce((select menge from bestaende where artikelnummer='${art}' and lagerplatz='${lp}'),0)`);
const delay = ms => execSync(`curl -s "${BASE}/__delay?ms=${ms}"`);

let ok = 0, fehler = 0;
async function test(name, fn) {
  reset(); delay(0);
  const browser = await chromium.launch();
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const jsFehler = [];
  page.on('pageerror', e => jsFehler.push(e.message));
  page.on('dialog', d => d.accept());   // alert()/confirm() außerhalb des Tests: annehmen
  await page.route(/cdn\.jsdelivr\.net/, r => {
    const key = Object.keys(CDN).find(k => r.request().url().includes(k));
    return key ? r.fulfill({ path: CDN[key], contentType: 'application/javascript' }) : r.abort();
  });
  try {
    await page.goto(BASE + '/index.html');
    await page.fill('#url', BASE); await page.fill('#key', 'testkey');
    await page.click('text=Verbinden');
    await page.fill('#email', 'test@lager.local'); await page.fill('#pass', 'x');
    await page.click('button:has-text("Anmelden")');
    await page.waitForSelector('#app', { state: 'visible' });
    await page.waitForSelector('.such-table');
    await fn(page, ctx);
    if (jsFehler.length) throw new Error('JavaScript-Fehler: ' + jsFehler.join(' | '));
    console.log('✅', name); ok++;
  } catch (e) {
    console.log('❌', name, '\n   ', e.message.split('\n')[0]); fehler++;
    await page.screenshot({ path: '/var/tmp/lp-e2e/fehler-' + name.replace(/\W+/g, '_') + '.png' }).catch(() => {});
  } finally { await browser.close(); }
}
const gleich = (ist, soll, was) => { if (String(ist) !== String(soll)) throw new Error(`${was}: erwartet ${soll}, ist ${ist}`); };
const scanne = async (page, feld, code) => { await page.focus(feld); await page.keyboard.type(code); await page.keyboard.press('Enter'); };

(async () => {
  await test('Start: Suche lädt ohne Fehler', async page => {
    const txt = await page.textContent('#such-status');
    if (!/4 Artikel/.test(txt)) throw new Error('Suche-Status: ' + txt);
  });

  await test('#7 Scanner: Doppelklick auf Platz-Knopf bucht nur einmal', async page => {
    await page.click('button[data-t="buchen"]');
    await page.click('#ss-mode-aus');
    await scanne(page, '#ss-scan', 'A1');
    await page.waitForSelector('#ss-pick-btns button:has-text("Regal 3")');
    delay(700);
    const btn = page.locator('#ss-pick-btns button:has-text("Regal 3")');
    await btn.click(); await btn.click({ force: true }).catch(() => {});
    await page.waitForSelector('#ss-status .ok', { timeout: 5000 });
    delay(0);
    gleich(menge('A1', 'Regal 3'), 11, 'Bestand Regal 3');
    gleich(sql("select count(*) from buchungen where typ='Ausgang'"), 1, 'Anzahl Ausgänge');
  });

  await test('#7 Suche: Doppelklick auf „+ Ein" bucht nur einmal', async page => {
    await page.fill('#suche', 'Offline'); await page.waitForTimeout(300);
    delay(700);
    const btn = page.locator('.such-table button.bk-ein').first();
    await btn.click(); await btn.click({ force: true }).catch(() => {});
    await page.waitForTimeout(1500); delay(0);
    gleich(sql("select count(*) from buchungen where typ='Eingang'"), 1, 'Anzahl Eingänge');
  });

  await test('#33 Suche: Tabelle zeigt nach Schnellbuchung den neuen Bestand ohne Komplett-Neuladen', async page => {
    await page.fill('#suche', 'Offline'); await page.waitForTimeout(300);
    const anfragen = [];
    page.on('request', r => { if (r.url().includes('/rest/v1/')) anfragen.push(r.url()); });
    const zeile = page.locator('.such-table tr', { hasText: 'QUELLE-1' });
    await zeile.locator('input[type=number]').fill('3');
    await zeile.locator('button.bk-ein').click();
    await page.waitForFunction(() => /\b13\b/.test(document.querySelector('.such-table').innerText));
    gleich(menge('A2', 'QUELLE-1'), 13, 'Bestand QUELLE-1');
    const komplett = anfragen.filter(u => /\/bestaende\?select=artikelnummer%2Clagerplatz%2Cmenge(&|$)/.test(u) || /bestaende\?select=lagerplatz&/.test(u) && !/menge=eq\.0/.test(u));
    gleich(komplett.length, 0, 'Komplett-Ladevorgänge der Bestandstabelle');
  });

  await test('#11 Suche: „Regal-1" und „Regal 1" werden nicht verwechselt', async page => {
    await page.fill('#suche', 'ähnliche'); await page.waitForTimeout(300);
    // beide Zeilen prüfen - die alte Version las je nach Reihenfolge das Feld der anderen Zeile
    for (const [lp, rest, andere, andereMenge] of [['Regal-1', 5, 'Regal 1', 3], ['Regal 1', 1, 'Regal-1', 5]]) {
      const zeile = page.locator('.such-table tr', { has: page.locator('span.lp', { hasText: new RegExp('^' + lp + '$') }) });
      await zeile.locator('input[type=number]').fill('2');
      await zeile.locator('button.bk-aus').click();
      await page.waitForTimeout(1000);
      gleich(menge('A3', lp), rest, 'Bestand „' + lp + '"');
      gleich(menge('A3', andere), andereMenge, 'Bestand „' + andere + '"');
    }
  });

  await test('#7 Umlagern: Doppelklick lagert nur einmal um', async page => {
    await page.click('button[data-t="umlagern"]');
    await page.fill('#u-artnr', 'A1'); await page.press('#u-artnr', 'Tab');
    await page.waitForSelector('#u-von option:has-text("Regal 4")', { state: 'attached' });
    await page.selectOption('#u-von', 'Regal 4');
    await page.selectOption('#u-nach', 'Regal 3');
    delay(700);
    await page.click('#u-btn'); await page.click('#u-btn', { force: true }).catch(() => {});
    await page.waitForSelector('#u-status .ok', { timeout: 5000 }); delay(0);
    gleich(menge('A1', 'Regal 4'), 4, 'Bestand Regal 4');
    gleich(sql("select count(*) from buchungen where typ='Umlagerung'"), 1, 'Anzahl Umlagerungen');
  });

  await test('#8 Scanner: Set-Rückfrage lässt sich nicht per Scan bestätigen', async page => {
    await page.click('button[data-t="buchen"]');
    await page.click('#ss-mode-aus');
    await scanne(page, '#ss-scan', '4000000000031');
    await page.waitForSelector('#scan-frage', { state: 'visible' });
    await page.keyboard.type('4000000000017'); await page.keyboard.press('Enter');   // nächster Scan
    await page.waitForTimeout(300);
    if (!(await page.isVisible('#scan-frage'))) throw new Error('Rückfrage wurde durch Scanner-Enter geschlossen');
    gleich(sql('select count(*) from buchungen'), 0, 'Buchungen vor Bestätigung');
    await page.click('#scan-frage-ja');
    await page.waitForSelector('#ss-status .ok');
    gleich(menge('SET1', 'Regal 3'), 3, 'Bestand Set');
    gleich(menge('A1', 'Regal 3'), 12, 'Bestand des „weggescannten" Artikels');
    const st = await page.textContent('#ss-status');
    if (!/nicht.*gebucht/i.test(st)) throw new Error('Kein Hinweis auf den verworfenen Scan: ' + st);
  });

  async function sortierungStarten(page) {
    await page.click('button[data-t="einraeumen"]');
    await page.waitForSelector('#er-quelle option[value="QUELLE-1"]', { state: 'attached' });
    await page.selectOption('#er-quelle', 'QUELLE-1');
    await page.selectOption('#er-palette', 'P01');
    await page.waitForSelector('#er-karton-wahl', { state: 'visible' });
    await page.click('button:has-text("Starten")');
    await page.waitForSelector('#er-run', { state: 'visible' });
  }

  await test('#8 Palette sortieren: Mehrmengen-Rückfrage ignoriert Enter, „Nein" bucht nichts', async page => {
    await sortierungStarten(page);
    await page.fill('#er-menge', '5');
    await scanne(page, '#er-scan', '4000000000017');   // A1: nur 2 auf der Quelle
    await page.waitForSelector('#scan-frage', { state: 'visible' });
    await page.keyboard.press('Enter'); await page.keyboard.press('Enter');
    await page.waitForTimeout(300);
    if (!(await page.isVisible('#scan-frage'))) throw new Error('Rückfrage wurde durch Enter geschlossen');
    await page.click('#scan-frage-nein');
    await page.waitForTimeout(300);
    gleich(sql('select count(*) from buchungen'), 0, 'Buchungen nach „Nein"');
  });

  await test('#9 Palette sortieren: schneller Folge-Scan wird abgewiesen und gemeldet', async page => {
    await sortierungStarten(page);
    delay(800);
    await scanne(page, '#er-scan', '4000000000024');   // A2 (offline)
    await page.waitForTimeout(100);
    await scanne(page, '#er-scan', '4000000000017');   // A1 kommt, während A2 noch läuft
    await page.waitForSelector('#er-status .ok', { timeout: 8000 });
    delay(0); await page.waitForTimeout(3000);   // Nachladen nach der Buchung abwarten
    gleich(menge('A2', 'P01-K02'), 1, 'A2 im Offline-Karton');
    gleich(menge('A1', 'P01-K01'), 0, 'A1 (abgewiesen) im Online-Karton');
    const st = await page.textContent('#er-status');
    if (!/nicht.*gebucht/i.test(st)) throw new Error('Kein Hinweis auf abgewiesenen Scan: ' + st);
    // Feld ist leer, kein angehängter Doppel-Code
    gleich(await page.inputValue('#er-scan'), '', 'Inhalt Scanfeld');
  });

  await test('#10 Palette fertig: beide Karton-Blätter in EINEM Fenster', async (page, ctx) => {
    await sortierungStarten(page);
    await scanne(page, '#er-scan', '4000000000024');
    await page.waitForSelector('#er-status .ok');
    await scanne(page, '#er-scan', '4000000000017');
    await page.waitForFunction(() => (document.querySelector('#er-status').innerText.match(/ONLINE →/) || []).length);
    const fenster = [];
    ctx.on('page', p => fenster.push(p));
    await page.evaluate(() => { window.print = () => {}; });
    await page.click('button:has-text("Palette fertig")');
    await page.waitForTimeout(1500);
    gleich(fenster.length, 1, 'Anzahl geöffneter Fenster');
    await fenster[0].waitForSelector('.blatt');
    const blaetter = await fenster[0].locator('.blatt').count();
    gleich(blaetter, 2, 'Karton-Blätter im Fenster');
    const txt = await fenster[0].textContent('body');
    if (!txt.includes('P01-K01') || !txt.includes('P01-K02')) throw new Error('Kartonnamen fehlen');
  });

  await test('#10 Nachdruck: Fehler beim Laden ergibt kein leeres Blatt', async (page, ctx) => {
    await page.click('button[data-t="kartons"]');
    await page.locator('.lager-btn').first().click();
    await page.waitForSelector('button:has-text("Nachdruck")');
    const fenster = [];
    ctx.on('page', p => fenster.push(p));
    await page.route(/\/rest\/v1\/bestaende/, r => r.abort());
    await page.locator('button:has-text("Nachdruck")').first().click();
    await page.waitForFunction(() => true);
    for (let i = 0; i < 30 && !(fenster[0] && /konnte nicht/.test(await fenster[0].textContent('body').catch(() => ''))); i++) await page.waitForTimeout(500);
    gleich(fenster.length, 1, 'Anzahl Fenster');
    const txt = await fenster[0].textContent('body');
    if (!/konnte nicht geladen werden/.test(txt)) throw new Error('Erwartete Fehlermeldung, Inhalt: ' + txt.slice(0, 120));
  });

  await test('#12 Suche: ausgeblendete Auswahl wird angezeigt', async page => {
    await page.fill('#suche', 'Online'); await page.waitForTimeout(300);
    await page.locator('.such-table tbody input[type=checkbox]').first().check();
    await page.fill('#suche', 'Offline'); await page.waitForTimeout(300);
    const bar = await page.textContent('#such-sammel');
    if (!/1 durch Suche\/Filter ausgeblendet/.test(bar)) throw new Error('Leiste: ' + bar);
  });

  await test('#33 Scanner: Buchung lädt nicht mehr die ganze Bestandstabelle', async page => {
    await page.click('button[data-t="buchen"]');
    await page.click('#ss-mode-aus');
    const anfragen = [];
    page.on('request', r => { if (r.url().includes('/rest/v1/bestaende')) anfragen.push(r.url()); });
    await scanne(page, '#ss-scan', '4000000000024');   // A2: nur auf QUELLE-1 → bucht direkt
    await page.waitForSelector('#ss-status .ok');
    await page.waitForTimeout(500);
    const komplett = anfragen.filter(u => /select=lagerplatz(&|$)/.test(u));
    gleich(komplett.length, 0, 'Komplett-Ladevorgänge');
    gleich(menge('A2', 'QUELLE-1'), 9, 'Bestand');
  });

  // ── Gegenprobe: unveränderte Funktionen laufen weiter ──
  await test('Gegenprobe: alle Reiter öffnen ohne Fehler', async page => {
    for (const t of ['buchen','umlagern','inventur','kartons','protokoll','import','uebersicht','einraeumen','suche']) {
      await page.click(`button[data-t="${t}"]`);
      await page.waitForTimeout(700);
    }
  });

  await test('Gegenprobe: Scanner Einbuchen auf gewählten Platz + Rückgängig', async page => {
    await page.click('button[data-t="buchen"]');
    await page.click('#ss-mode-ein');
    await page.click('#ss-lp-btns button:has-text("Regal 4")');
    await page.fill('#ss-menge', '3');
    await scanne(page, '#ss-scan', '4000000000017');
    await page.waitForSelector('#ss-status .ok');
    gleich(menge('A1', 'Regal 4'), 8, 'Bestand nach Einbuchen');
    await page.waitForSelector('#undo-bar-btn', { state: 'visible' });
    await page.click('#undo-bar-btn');
    await page.waitForTimeout(1000);
    gleich(menge('A1', 'Regal 4'), 5, 'Bestand nach Rückgängig');
  });

  await test('Gegenprobe: unbekannte EAN beim Einbuchen → Klärfall-Karton', async page => {
    await page.click('button[data-t="buchen"]');
    await page.click('#ss-mode-ein');
    await scanne(page, '#ss-scan', '4999999999999');
    await page.waitForSelector('#ss-status .ss-unbekannt');
    gleich(sql("select count(*) from bestaende where lagerplatz like 'Unbekannt-%' and menge > 0"), 1, 'Zeilen im Klärfall-Karton');
  });

  await test('Gegenprobe: Scanner Einbuchen ohne Platz → Platzwahl → Buchung', async page => {
    await page.click('button[data-t="buchen"]');
    await page.click('#ss-mode-ein');
    await scanne(page, '#ss-scan', '4000000000024');
    await page.locator('#ss-pick-btns button', { hasText: 'Alt-Platz' }).click();
    await page.waitForSelector('#ss-status .ok');
    gleich(menge('A2', 'Alt-Platz'), 1, 'Bestand auf früherem (leerem) Platz');
  });

  await test('Gegenprobe: Umlagern auf neuen Platz, danach im Scanner wählbar', async page => {
    await page.click('button[data-t="umlagern"]');
    await page.fill('#u-artnr', 'A1'); await page.press('#u-artnr', 'Tab');
    await page.waitForSelector('#u-von option:has-text("Regal 4")', { state: 'attached' });
    await page.selectOption('#u-von', 'Regal 4');
    await page.selectOption('#u-nach', '__neu__');
    await page.fill('#u-nach-neu', 'Neu-Platz');
    await page.click('#u-btn');
    await page.waitForSelector('#u-status .ok');
    await page.click('button[data-t="buchen"]');
    await page.click('#ss-mode-ein');
    await page.waitForSelector('#ss-lp-btns button:has-text("Neu-Platz")');
  });

  console.log(`\n${ok} bestanden, ${fehler} fehlgeschlagen`);
  process.exit(fehler ? 1 : 0);
})();
