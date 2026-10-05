// Browser-Tests für Paket 3b/3c (Bibliotheken, Exporte, Glocke, Texte, Backup, JTL).
// Aufruf: NODE_PATH=$(npm root -g) node tests/e2e/paket3bc.test.js
const fs = require('fs');
const { BASE, sql, gleich, test, ende } = require('./hilfe');
const herunterladen = async (page, knopf) => {
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click(knopf)]);
  return fs.readFileSync(await dl.path(), 'utf8');
};

(async () => {
  await test('Bibliotheken mit fester Version und Prüfsumme', async page => {
    const skripte = await page.$$eval('script[src]', l => l.map(s => ({ src: s.src, integrity: s.integrity, co: s.crossOrigin })));
    gleich(skripte.length, 3, 'Anzahl externer Skripte');
    for (const s of skripte) {
      if (!/@\d+\.\d+\.\d+\//.test(s.src)) throw new Error('keine feste Version: ' + s.src);
      if (!/^sha384-/.test(s.integrity) || s.co !== 'anonymous') throw new Error('keine Prüfsumme: ' + s.src);
    }
  });

  await test('Veränderte Bibliothek wird vom Browser blockiert', async (page, ctx) => {
    const p2 = await ctx.newPage();
    await p2.route(/cdn\.jsdelivr\.net/, r => r.fulfill({ body: 'window.manipuliert = true;', contentType: 'application/javascript',
      headers: { 'Access-Control-Allow-Origin': '*' } }));
    await p2.goto(BASE + '/index.html').catch(() => {});
    await p2.waitForTimeout(500);
    gleich(await p2.evaluate(() => window.manipuliert === true), false, 'manipuliertes Skript ausgeführt');
    await p2.close();
  });

  await test('Exporte: Excel-Formeln entschärft, JTL-Datei unverändert', async page => {
    sql("insert into artikel (artikelnummer, artikelname, gtin, ist_set, online) values ('=F1', '=HYPERLINK(\"http://x\")', '', 0, 1)");
    sql("insert into bestaende values ('=F1', 'Regal 3', 2)");
    await page.click('button[data-t="import"]');
    const art = await herunterladen(page, 'button:has-text("Artikel (mit Bestand)")');
    const zeile = art.split(/\r\n/).find(z => z.includes('HYPERLINK'));
    if (!zeile.startsWith("'=F1;\"'=HYPERLINK(")) throw new Error('nicht entschärft: ' + zeile);
    const jtl = await herunterladen(page, 'button:has-text("Lagerbestand (JTL)")');
    if (!jtl.split(/\r\n/).includes('=F1;Regal 3;2')) throw new Error('JTL-Datei verändert: ' + jtl.slice(0, 200));
  });

  await test('JTL-Kommentar: Knopf liefert die Datei der Datenbank', async page => {
    sql("insert into bestaende values ('A2', 'Regal 3', 0)");
    await page.click('button[data-t="import"]');
    const datei = await herunterladen(page, 'button:has-text("Lagerbestandskommentar")');
    const erwartet = '﻿' + JSON.parse(sql("select jtl_kommentar_csv()")).csv;
    gleich(datei === erwartet, true, 'Datei = jtl_kommentar_csv()');
    if (!datei.includes('\r\nA1;QUELLE-1 (2), Regal 3 (12), Regal 4 (5)\r\n')) throw new Error('Inhalt: ' + JSON.stringify(datei.slice(0, 200)));
  });

  await test('Glocke: im Hintergrund keine Abfragen, Liste nur bei offener Glocke', async page => {
    const anfragen = [];
    page.on('request', r => { if (r.url().includes('/rest/v1/')) anfragen.push(r.url()); });
    await page.evaluate(() => Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }));
    await page.evaluate(() => hintergrundTick()); await page.waitForTimeout(400);
    gleich(anfragen.length, 0, 'Abfragen im Hintergrund');
    await page.evaluate(() => Object.defineProperty(document, 'hidden', { configurable: true, get: () => false }));
    await page.evaluate(() => hintergrundTick()); await page.waitForTimeout(400);
    const leer = anfragen.filter(u => u.includes('leermeldungen'));
    gleich(leer.length, 1, 'nur die Anzahl wird abgefragt (Glocke zu)');
    await page.click('#glocke'); await page.waitForTimeout(400);
    if (!anfragen.some(u => u.includes('leermeldungen') && u.includes('zeitstempel'))) throw new Error('Liste beim Öffnen nicht geladen');
  });

  await test('Texte und Protokollfilter', async page => {
    await page.click('button[data-t="import"]');
    const txt = await page.textContent('#tab-import');
    if (/Backdatei/.test(txt) || /alles_loeschen\.sql/.test(await page.content())) throw new Error('alter Text');
    if (!/Palettenliste/.test(txt) || !/Dropbox/.test(txt)) throw new Error('Hinweise fehlen');
    for (const t of ['Palette angelegt', 'Palette umbenannt', 'Artikel angelegt', 'Artikeländerung (Import)'])
      gleich(await page.locator(`#prot-typ option:text-is("${t}")`).count(), 1, 'Filter ' + t);
  });

  await test('Sicherung: einheitliches Format, wieder einspielbar', async page => {
    await page.click('button[data-t="import"]');
    const json = JSON.parse(await herunterladen(page, 'button:has-text("Sicherung jetzt herunterladen")'));
    gleich(json.format, 'lagerpal-backup', 'format'); gleich(json.version, 2, 'version');
    if (!json.erstellt_am || json.erstellt) throw new Error('Feldname erstellt_am');
    fs.writeFileSync('/var/tmp/lp-e2e/sicherung.json', JSON.stringify(json));
    sql("delete from bestaende where artikelnummer = 'A3'");
    sql("select backup_wiederherstellen(pg_read_file('/var/tmp/lp-e2e/sicherung.json')::jsonb)");
    gleich(sql("select sum(menge) from bestaende where artikelnummer = 'A3'"), 10, 'A3 wiederhergestellt');
  });

  ende();
})();
