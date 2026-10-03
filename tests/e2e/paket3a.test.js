// Browser-Tests für Paket 3a (Datenrichtigkeit bei Import, Inventur, Export).
// Aufruf: NODE_PATH=$(npm root -g) node tests/e2e/paket3a.test.js
const fs = require('fs');
const XLSX = require('/var/tmp/lp-e2e/node_modules/xlsx');
const { sql, menge, gleich, scanne, test, ende } = require('./hilfe');

// Excel-Datei mit ZAHLEN-Zellen (so verliert Excel führende Nullen)
function excel(datei, zeilen) {
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(zeilen), 'Tabelle1');
  XLSX.writeFile(wb, datei);
}

(async () => {
  await test('Excel-Import: fehlende führende Nullen werden erkannt, ungültige EAN nicht übernommen', async page => {
    sql("update artikel set gtin = '0012345678905' where artikelnummer = 'A2'");
    sql("insert into artikel (artikelnummer, artikelname, gtin, ist_set, online) values ('00777', 'Nullen-Artikel', '', 0, 1)");
    const datei = '/var/tmp/lp-e2e/nullen.xlsx';
    excel(datei, [['Artikelnummer', 'Lagerplatz', 'Bestand', 'EAN'],
      ['A2', 'QUELLE-1', 10, 12345678905],      // EAN ohne Nullen → vorhandene bleibt
      ['A1', 'Regal 3', 12, 123],               // ungültig → nicht übernehmen
      [777, 'Regal 7', 4, '']]);                // Artikelnummer ohne Nullen → 00777
    await page.click('button[data-t="import"]');
    await page.check('#bimp-anlegen');
    await page.setInputFiles('#bimp-file', datei);
    await page.waitForSelector('#bimp-result button:has-text("Import ausführen")');
    const txt = await page.textContent('#bimp-result');
    if (!/Artikelnummer\(n\) ohne führende Nullen/.test(txt) || !/777 → 00777/.test(txt)) throw new Error('Artikelnummer-Hinweis fehlt: ' + txt.slice(0, 300));
    if (!/EAN\(s\) ohne führende Nullen/.test(txt)) throw new Error('EAN-Hinweis fehlt');
    if (!/falscher Länge oder Prüfziffer/.test(txt) || !/A1: 123/.test(txt)) throw new Error('Ungültige EAN nicht gemeldet');
    if (/bekommen geänderte Stammdaten/.test(txt)) throw new Error('Stammdaten-Änderung angezeigt, obwohl keine');
    await page.click('#bimp-result button:has-text("Import ausführen")');
    await page.waitForSelector('#bimp-result :text("Import erfolgreich")');
    gleich(sql("select gtin from artikel where artikelnummer = 'A2'"), '0012345678905', 'EAN A2');
    gleich(sql("select gtin from artikel where artikelnummer = 'A1'"), '4000000000017', 'EAN A1');
    gleich(menge('00777', 'Regal 7'), 4, 'Bestand beim richtigen Artikel');
    gleich(sql("select count(*) from artikel where artikelnummer = '777'"), 0, 'kein falscher Artikel angelegt');
  });

  await test('Import: Stammdaten-Änderungen in der Vorschau und im Protokoll', async page => {
    const datei = '/var/tmp/lp-e2e/stamm.csv';
    fs.writeFileSync(datei, 'Artikelnummer;Lagerplatz;Bestand;Artikelname;Set\nA1;Regal 3;12;Neuer Name;0\nA3;Regal-1;7;;ja\n');
    await page.click('button[data-t="import"]');
    await page.setInputFiles('#bimp-file', datei);
    await page.waitForSelector('#bimp-result :text("bekommen geänderte Stammdaten")');
    let txt = await page.textContent('#bimp-result');
    // ohne Haken: nur das Set-Kennzeichen ändert sich
    if (!/1 Artikel bekommen/.test(txt) || /Neuer Name/.test(txt)) throw new Error('ohne Haken: ' + txt.slice(0, 300));
    await page.check('#bimp-anlegen');                     // Vorschau wird neu berechnet
    await page.waitForSelector('#bimp-result :text("2 Artikel bekommen")');
    txt = await page.textContent('#bimp-result');
    if (!/Testartikel Online → Neuer Name/.test(txt)) throw new Error('Namensänderung fehlt: ' + txt.slice(0, 300));
    await page.click('#bimp-result button:has-text("Import ausführen")');
    await page.waitForSelector('#bimp-result :text("Stammdaten geändert")');
    await page.click('button[data-t="protokoll"]');
    await page.selectOption('#prot-typ', 'Artikeländerung (Import)');
    await page.waitForSelector('#protokoll-body :text("Neuer Name")');
    await page.waitForSelector('#protokoll-body :text("Set: nein → ja")');
  });

  await test('Inventur: leerer Platz wählbar, gefundene Ware wird gebucht', async page => {
    sql("insert into lagerplaetze (name) values ('Leerplatz')");
    await page.click('button[data-t="inventur"]');
    await page.waitForSelector('#inv-lp option[value="Leerplatz"]', { state: 'attached' });
    gleich(await page.textContent('#inv-lp option[value="Leerplatz"]'), 'Leerplatz (leer)', 'Beschriftung');
    await page.selectOption('#inv-lp', 'Leerplatz');
    await page.waitForSelector('#inv-table :text("nichts")');
    await scanne(page, '#inv-add', 'A2');
    await page.waitForSelector('#inv-table input');
    await page.fill('#inv-table input', '3'); await page.press('#inv-table input', 'Tab');
    await page.click('button:has-text("Inventur übernehmen")');
    await page.waitForSelector('#inv-status .ok');
    gleich(menge('A2', 'Leerplatz'), 3, 'gezählte Menge');
  });

  await test('Inventur: Buchung während der Zählung wird nicht überschrieben', async page => {
    await page.click('button[data-t="inventur"]');
    await page.waitForSelector('#inv-lp option[value="Regal 3"]', { state: 'attached' });
    await page.selectOption('#inv-lp', 'Regal 3');
    await page.waitForSelector('#inv-table input');
    const zeile = page.locator('#inv-table tr', { hasText: 'A1' });
    await zeile.locator('input').fill('10'); await zeile.locator('input').press('Tab');
    sql("update bestaende set menge = 11 where artikelnummer = 'A1' and lagerplatz = 'Regal 3'");  // anderes Gerät bucht 1 aus
    await page.click('button:has-text("Inventur übernehmen")');
    await page.waitForSelector('#inv-status :text("Während der Zählung")');
    gleich(menge('A1', 'Regal 3'), 11, 'nichts übernommen');
    await page.waitForSelector('#inv-table :text("Soll war 12, jetzt 11")');
    await page.click('button:has-text("Inventur übernehmen")');      // geprüft → erneut übernehmen
    await page.waitForSelector('#inv-status .ok');
    gleich(menge('A1', 'Regal 3'), 10, 'nach Bestätigung übernommen');
  });

  await test('Amazon-Import: unbekannter Status wird nicht still „online"', async page => {
    sql("update artikel set online = 2 where artikelnummer in ('A1','A2')");
    const datei = '/var/tmp/lp-e2e/amazon.csv';
    fs.writeFileSync(datei, 'SKU;Status\nA1;Gesperrt\nA2;Aktiv\nSET1;Gesperrt\n');
    await page.click('button[data-t="import"]');
    await page.setInputFiles('#imp-file', datei);
    await page.waitForSelector('#imp-result :text("Unbekannte Statuswerte")');
    let txt = await page.textContent('#imp-result');
    if (!/„Gesperrt"\s*\(2×\)/.test(txt)) throw new Error('Wert fehlt: ' + txt.slice(0, 300));
    if (!/auf online: 1/.test(txt.replace(/\s+/g, ' '))) throw new Error('Zählung: ' + txt.slice(0, 300));
    await page.click('#imp-result button:has-text("Status übernehmen")');
    await page.waitForSelector('#imp-result :text("übernommen")');
    gleich(sql("select online from artikel where artikelnummer = 'A1'"), 2, 'A1 unverändert nicht online');
    gleich(sql("select online from artikel where artikelnummer = 'SET1'"), 1, 'SET1 unverändert online');
    gleich(sql("select online from artikel where artikelnummer = 'A2'"), 1, 'A2 online');
    if (!/geändert: 1\b/.test(await page.textContent('#imp-result'))) throw new Error('Erfolgsmeldung zählt falsch');
    // Zuordnung „nicht online" wählen und erneut importieren
    await page.setInputFiles('#imp-file', datei);
    await page.waitForSelector('#imp-result select');
    await page.selectOption('#imp-result select', '2');
    await page.waitForSelector('#imp-result :text("nicht online: 1")');
    await page.click('#imp-result button:has-text("Status übernehmen")');
    await page.waitForSelector('#imp-result :text("übernommen")');
    gleich(sql("select online from artikel where artikelnummer = 'SET1'"), 2, 'SET1 jetzt nicht online');
    // Auswahl wird gemerkt
    await page.setInputFiles('#imp-file', datei);
    await page.waitForSelector('#imp-result select');
    gleich(await page.inputValue('#imp-result select'), '2', 'gemerkte Zuordnung');
  });

  await test('Artikel-Export: Gesamtbestand stimmt auch bei „:" im Platznamen', async page => {
    sql("insert into bestaende values ('A2', 'A:1', 5)");
    await page.click('button[data-t="import"]');
    const [dl] = await Promise.all([page.waitForEvent('download'), page.click('button:has-text("Artikel (mit Bestand)")')]);
    const inhalt = fs.readFileSync(await dl.path(), 'utf8');
    const a2 = inhalt.split(/\r\n/).find(z => z.startsWith('A2;'));
    gleich(a2.split(';')[5], 15, 'Gesamtbestand A2 (10 + 5)');
  });

  ende();
})();
