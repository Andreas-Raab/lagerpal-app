// Browser-Tests zu den Rückmeldungen aus dem ersten Test im Testsystem.
// Aufruf: NODE_PATH=$(npm root -g) node tests/e2e/rueckmeldung1.test.js
const fs = require('fs');
const { sql, menge, gleich, scanne, test, ende } = require('./hilfe');
const zweiMitGleicherEan = () => sql("insert into artikel (artikelnummer, artikelname, gtin, ist_set, online) values ('A1-DEF','Testartikel Online (Defekt)','4000000000017',0,2)");

(async () => {
  await test('Mehrdeutige EAN im Scanner: Auswahl statt Fehler, gewählter Artikel wird gebucht', async page => {
    zweiMitGleicherEan(); sql("insert into bestaende values ('A1-DEF','Regal 9',4)");
    await page.click('button[data-t="buchen"]'); await page.click('#ss-mode-aus');
    await scanne(page, '#ss-scan', '4000000000017');
    await page.waitForSelector('#scan-frage-optionen button');
    gleich(await page.locator('#scan-frage-optionen button').count(), 2, 'Auswahlmöglichkeiten');
    await page.click('#scan-frage-optionen button:has-text("A1-DEF")');
    await page.waitForSelector('#ss-status .ok');
    gleich(menge('A1-DEF', 'Regal 9'), 3, 'ausgebucht vom gewählten Artikel');
    gleich(menge('A1', 'Regal 3'), 12, 'anderer Artikel unverändert');
  });

  await test('Mehrdeutige EAN: Abbrechen bucht nichts, Scanner bleibt bedienbar', async page => {
    zweiMitGleicherEan();
    await page.click('button[data-t="buchen"]'); await page.click('#ss-mode-aus');
    await scanne(page, '#ss-scan', '4000000000017');
    await page.waitForSelector('#scan-frage-optionen button');
    await page.click('#scan-frage-nein');
    await page.waitForTimeout(300);
    gleich(sql('select count(*) from buchungen'), 0, 'Buchungen');
    await scanne(page, '#ss-scan', '4000000000024');
    await page.waitForSelector('#ss-status .ok');
  });

  await test('Mehrdeutige EAN beim Umlagern: Auswahl übernimmt die Artikelnummer', async page => {
    zweiMitGleicherEan();
    await page.click('button[data-t="umlagern"]');
    await page.fill('#u-artnr', '4000000000017'); await page.press('#u-artnr', 'Tab');
    await page.waitForSelector('#scan-frage-optionen button');
    await page.click('#scan-frage-optionen button:has-text("Testartikel Online ·")');
    await page.waitForFunction(() => document.getElementById('u-artnr').value === 'A1');
  });

  await test('Abgleich: Menge per +/− und Eingabe wählbar, Grenzen sichtbar', async page => {
    sql("select karton_setzen('P01-K01','P01',1)"); sql("select einraeumen_scan('A1','QUELLE-1','P01-K01',5)");
    await page.click('button[data-t="abgleich"]');
    await page.click('.abg-fall button:has-text("Mehr war echt neu")');
    if (!(await page.isDisabled('.abg-step button[aria-label="mehr"]'))) throw new Error('+ am Maximum nicht ausgegraut');
    if (!/max\. 3/.test(await page.textContent('.abg-best'))) throw new Error('Maximum nicht angezeigt');
    await page.click('.abg-step button[aria-label="weniger"]');
    gleich(await page.inputValue('#abg-menge'), '2', 'nach −');
    await page.click('.abg-step button[aria-label="mehr"]');
    gleich(await page.inputValue('#abg-menge'), '3', 'nach +');
    await page.fill('#abg-menge', '1'); await page.press('#abg-menge', 'Tab');
    gleich(await page.inputValue('#abg-menge'), '1', 'nach Eingabe');
    await page.click('#abg-ok'); await page.waitForSelector('#abg-status .ok');
    gleich(sql("select offen from mengen_abweichungen where art='mehr'"), 2, 'offen nach Teilmenge');
  });

  await test('Teil-Import-Vorschau zeigt nur echte Änderungen', async page => {
    const datei = '/var/tmp/lp-e2e/teil3.csv';
    fs.writeFileSync(datei, 'Artikelnummer;Lagerplatz;Bestand\nA1;Regal 3;12\nA1;Regal 4;7\nA2;QUELLE-1;10\nGIBTSNICHT;Regal 1;1\n');
    await page.click('button[data-t="import"]');
    await page.setInputFiles('#bimp-file', datei);
    await page.waitForSelector('#bimp-result button:has-text("Import ausführen")');
    const txt = await page.textContent('#bimp-result');
    if (!/1 Plätze ändern sich/.test(txt) || !/2 bleiben gleich/.test(txt)) throw new Error('Zählung: ' + txt.slice(0, 200));
    gleich(await page.locator('#bimp-result table tr').count(), 2, 'Tabellenzeilen (Kopf + 1 Änderung)');
    if (!/5 → 7/.test(txt)) throw new Error('Änderung fehlt');
  });

  await test('Kopf, Reiter und Spaltenköpfe bleiben beim Scrollen stehen', async page => {
    sql("insert into artikel select 'Z'||g, 'Zusatzartikel '||g, '', 0, 1 from generate_series(1,80) g");
    sql("insert into bestaende select 'Z'||g, 'Regal Z', 1 from generate_series(1,80) g");
    await page.reload(); await page.waitForSelector('.such-table');
    await page.evaluate(() => sucheMehrLaden());
    await page.mouse.wheel(0, 3000); await page.waitForTimeout(300);
    const box = el => page.locator(el).first().boundingBox();
    const tabs = await box('.tabs'), kopf = await box('header');
    if (kopf.y < -1 || tabs.y < kopf.y + kopf.height - 2) throw new Error('Kopf/Reiter nicht oben: ' + JSON.stringify({ kopf, tabs }));
    // Spaltenkopf sitzt direkt unter den Reitern und ist sichtbar
    const th = await box('.such-table thead th');
    if (Math.abs(th.y - (tabs.y + tabs.height)) > 3) throw new Error('Spaltenkopf nicht unter den Reitern: th ' + th.y + ', Reiter-Unterkante ' + (tabs.y + tabs.height));
    // schmaler Bildschirm: Tabelle scrollt in sich, Kopf bleibt oben in der Tabelle
    await page.setViewportSize({ width: 420, height: 800 }); await page.waitForTimeout(300);
    await page.locator('#such-tabelle').scrollIntoViewIfNeeded();
    await page.locator('#such-tabelle').evaluate(e => { e.scrollTop = 1500; }); await page.waitForTimeout(200);
    const th2 = await box('.such-table thead th'), cont = await box('#such-tabelle');
    if (Math.abs(th2.y - cont.y) > 2) throw new Error('Handy: Spaltenkopf scrollt weg');
    const sw = await page.evaluate(() => document.documentElement.scrollWidth);
    if (sw > 425) throw new Error('Seite scrollt seitlich: ' + sw);
  });

  ende();
})();
