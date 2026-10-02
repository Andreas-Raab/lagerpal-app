// Browser-Tests für Paket 2. Voraussetzung: tests/e2e/start.sh läuft.
// Aufruf: NODE_PATH=$(npm root -g) node tests/e2e/paket2.test.js
const fs = require('fs');
const { sql, menge, gleich, scanne, test, ende } = require('./hilfe');

(async () => {
  await test('#14 Zwei Geräte legen gleichzeitig neue Kartons an → verschiedene Nummern', async (page, ctx, zweite) => {
    const page2 = await zweite();
    const neu = p => p.evaluate(async () => { erSession = { pal: 'P05', counter: 0 }; return erNeuerKarton(1); });
    const [a, b] = await Promise.all([neu(page), neu(page2)]);
    if (a === b) throw new Error('beide bekamen ' + a);
    gleich([a, b].sort().join(','), 'P05-K01,P05-K02', 'Kartonnamen');
  });

  await test('#21 Sammel-Ausbuchen → Rückgängig-Leiste nimmt alles zurück', async page => {
    await page.fill('#suche', 'Online'); await page.waitForTimeout(300);
    await page.locator('.such-table tbody input[type=checkbox]').first().check();
    await page.click('#such-sammel button:has-text("Komplett ausbuchen")');
    await page.waitForTimeout(1000);
    gleich(menge('A1', 'Regal 3'), 0, 'nach Sammel-Ausbuchen');
    await page.evaluate(() => refreshUndo());
    await page.waitForSelector('#undo-bar-btn', { state: 'visible' });
    await page.click('#undo-bar-btn');
    await page.waitForTimeout(1000);
    gleich(menge('A1', 'Regal 3') + '/' + menge('A1', 'Regal 4') + '/' + menge('A1', 'QUELLE-1'), '12/5/2', 'Bestände nach Rückgängig');
    const txt = await page.textContent('#undo-bar-info');
    if (!/weitere Teile/.test(txt)) throw new Error('Leiste: ' + txt);
  });

  await test('#32 Glocke zeigt Sammel-Ausbuchen als normale Leermeldung mit Artikel und Platz', async page => {
    sql("select sammel_ausbuchen(array['A2'])");
    await page.evaluate(() => { toggleLeerPanel(); });
    await page.waitForTimeout(800);
    const txt = await page.textContent('#leer-panel-body');
    if (/Einräum-Hinweis/.test(txt)) throw new Error('als Einräum-Hinweis angezeigt');
    if (!/Testartikel Offline/.test(txt) || !/QUELLE-1/.test(txt)) throw new Error('Artikel/Platz fehlt: ' + txt.slice(0, 200));
  });

  await test('#35 Protokollsuche findet auch Buchungen jenseits der neuesten 200', async page => {
    sql("select buchen('A3','Regal 1','aus',1,'')");                     // die gesuchte, alte Buchung
    sql("select buchen('A1','Regal 3','ein',1,'') from generate_series(1,250)");
    await page.click('button[data-t="protokoll"]');
    await page.fill('#prot-suche', 'ähnliche');
    await page.waitForTimeout(1200);
    const txt = await page.textContent('#protokoll-body');
    if (!/Zwei ähnliche Plätze/.test(txt)) throw new Error('alte Buchung nicht gefunden');
    await page.fill('#prot-suche', 'gibtsnicht');
    await page.waitForTimeout(1200);
    if (!/gesamtes Protokoll durchsucht/.test(await page.textContent('#protokoll-body'))) throw new Error('Hinweis fehlt');
  });

  await test('#23 Teil-Import zeigt erst eine Vorschau und schreibt erst nach Bestätigung', async page => {
    const datei = '/var/tmp/lp-e2e/teil.csv';
    fs.writeFileSync(datei, 'Artikelnummer;Lagerplatz;Bestand\nA1;Regal 3;20\nA2;QUELLE-1;4\n');
    await page.click('button[data-t="import"]');
    await page.setInputFiles('#bimp-file', datei);
    await page.waitForSelector('#bimp-result button:has-text("Import ausführen")');
    const txt = await page.textContent('#bimp-result');
    if (!/12 → 20/.test(txt)) throw new Error('Vorschau ohne vorher→nachher: ' + txt.slice(0, 200));
    gleich(menge('A1', 'Regal 3'), 12, 'Bestand vor Bestätigung');
    await page.click('#bimp-result button:has-text("Import ausführen")');
    await page.waitForSelector('#bimp-result:has-text("Import erfolgreich")');
    gleich(menge('A1', 'Regal 3'), 20, 'Bestand nach Bestätigung');
  });

  await test('#45 Scanner: Netzfehler beim Nachschlagen → Meldung, nächster Scan funktioniert', async page => {
    await page.click('button[data-t="buchen"]');
    await page.click('#ss-mode-aus');
    await page.route(/\/rest\/v1\/artikel/, r => r.abort());
    await scanne(page, '#ss-scan', '4000000000024');
    await page.waitForSelector('#ss-status .err');
    const txt = await page.textContent('#ss-status');
    if (/Nicht gefunden/.test(txt)) throw new Error('Netzfehler als „nicht gefunden" gemeldet');
    await page.unroute(/\/rest\/v1\/artikel/);
    await scanne(page, '#ss-scan', '4000000000024');
    await page.waitForSelector('#ss-status .ok');
    gleich(menge('A2', 'QUELLE-1'), 9, 'Bestand nach zweitem Scan');
  });

  await test('#34 Mehr als 1000 Lagerplätze: Inventur und Lagerplätze zeigen alle', async page => {
    sql("insert into bestaende select 'A2', 'X-' || lpad(g::text, 4, '0'), 1 from generate_series(1, 1100) g");
    await page.click('button[data-t="inventur"]');
    await page.waitForFunction(() => document.querySelectorAll('#inv-lp option').length > 1000, null, { timeout: 15000 });
    const n = await page.locator('#inv-lp option').count();
    if (n < 1100) throw new Error('Inventur-Auswahl hat nur ' + n + ' Einträge');
    await page.evaluate(() => ladeAllePlaetze());
    await page.click('button[data-t="buchen"]'); await page.click('#ss-mode-ein');
    const k = await page.locator('#ss-lp-btns button').count();
    if (k < 1100) throw new Error('Scanner-Platzknöpfe: nur ' + k);
  });

  await test('#20 Lagerplatz löschen und zurücknehmen: Palette/Kanal bleiben', async page => {
    sql("select karton_setzen('P09-K01','P09',1)"); sql("select buchen('A1','P09-K01','ein',2,'')");
    sql("select lagerplatz_loeschen('P09-K01', true)");
    await page.evaluate(() => refreshUndo());
    await page.waitForSelector('#undo-bar-btn', { state: 'visible' });
    await page.click('#undo-bar-btn'); await page.waitForTimeout(800);
    gleich(sql("select palette||'/'||kanal from lagerplaetze where name='P09-K01'"), 'P09/1', 'Palette/Kanal');
  });

  ende();
})();
