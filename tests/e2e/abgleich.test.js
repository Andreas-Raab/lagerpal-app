// Browser-Tests für den Reiter „Abgleich". Voraussetzung: tests/e2e/start.sh läuft.
// Aufruf: NODE_PATH=$(npm root -g) node tests/e2e/abgleich.test.js
const { sql, menge, gleich, scanne, test, ende } = require('./hilfe');

// Ausgangslage: A1 lag in Wahrheit auf QUELLE-1 statt auf „Regal 4"
function szenario() {
  sql("select karton_setzen('P01-K01','P01',1)");
  sql("select einraeumen_scan('A1','QUELLE-1','P01-K01',5)");   // 3 zu viel
  sql("select einraeumen_rest_melden('Regal 4','P01')");         // 5 fehlen auf Regal 4
}
const offen = (art) => sql(`select coalesce(sum(offen),0) from mengen_abweichungen where artikelnummer='A1' and art='${art}'`);

(async () => {
  await test('Abgleich: Fall wird angezeigt (Name, Gesamtbestand, beide Seiten)', async page => {
    szenario();
    await page.click('button[data-t="abgleich"]');
    await page.waitForSelector('.abg-fall');
    const txt = await page.textContent('.abg-fall');
    for (const s of ['Testartikel Online', 'Gesamtbestand laut System: 22', '+3', 'QUELLE-1', 'P01-K01', '−5', 'Regal 4', 'teilweise'])
      if (!txt.includes(s)) throw new Error('fehlt: ' + s + ' | ' + txt.slice(0, 200));
  });

  await test('Abgleich: Ausgleichen bucht von der Fehl-Palette aus, Rückgängig-Leiste nimmt es zurück', async page => {
    szenario();
    await page.click('button[data-t="abgleich"]');
    await page.click('.abg-fall button:has-text("Ausgleichen")');
    await page.click('#abg-ok');
    await page.waitForSelector('#abg-status .ok');
    gleich(menge('A1', 'Regal 4'), 2, 'Regal 4 nach Ausgleich');
    gleich(offen('mehr') + '/' + offen('fehlt'), '0/2', 'offen mehr/fehlt');
    await page.waitForSelector('#undo-bar-btn', { state: 'visible' });
    await page.click('#undo-bar-btn');
    await page.waitForTimeout(1200);
    gleich(menge('A1', 'Regal 4'), 5, 'Regal 4 nach Rückgängig');
    gleich(offen('mehr') + '/' + offen('fehlt'), '3/5', 'offen nach Rückgängig');
    const txt = await page.textContent('#abg-liste');
    if (!txt.includes('+3')) throw new Error('Reiter nach Rückgängig nicht aktualisiert');
  });

  await test('Abgleich: Fehlt wirklich → Inventurdifferenz mit Teilmenge', async page => {
    szenario();
    await page.click('button[data-t="abgleich"]');
    await page.click('.abg-fall button:has-text("Fehlt wirklich")');
    await page.click('.abg-step button[aria-label="weniger"]'); await page.click('.abg-step button[aria-label="weniger"]');
    await page.click('#abg-ok');
    await page.waitForSelector('#abg-status .ok');
    gleich(menge('A1', 'Regal 4'), 2, 'Regal 4 nach 3 Stk Inventurdifferenz');
    gleich(sql("select typ from buchungen order by id desc limit 1"), 'Inventurdifferenz', 'Protokolltyp');
  });

  await test('Abgleich: Mehr war echt neu → erledigt, Bestand bleibt', async page => {
    sql("select karton_setzen('P01-K01','P01',1)"); sql("select einraeumen_scan('A2','QUELLE-1','P01-K01',12)");
    await page.click('button[data-t="abgleich"]');
    await page.click('.abg-fall button:has-text("Mehr war echt neu")');
    await page.click('#abg-ok');
    await page.waitForSelector('#abg-status .ok');
    gleich(menge('A2', 'P01-K01'), 12, 'Karton unverändert');
    await page.waitForSelector('#abg-liste:has-text("Keine offenen Fälle")');
    await page.click('button[data-abgf="erledigt"]');
    await page.waitForSelector('.abg-fall.erledigt');
  });

  await test('Abgleich: Matrix zeigt Paletten als Spalten', async page => {
    szenario();
    await page.click('button[data-t="abgleich"]');
    await page.click('button[data-abgv="matrix"]');
    await page.waitForSelector('.abg-matrix');
    const kopf = await page.textContent('.abg-matrix thead');
    if (!kopf.includes('QUELLE-1') || !kopf.includes('Regal 4')) throw new Error('Spalten: ' + kopf);
  });

  await test('Palette sortieren: Mehrmenge erscheint im Abgleich', async page => {
    await page.click('button[data-t="einraeumen"]');
    await page.waitForSelector('#er-quelle option[value="QUELLE-1"]', { state: 'attached' });
    await page.selectOption('#er-quelle', 'QUELLE-1'); await page.selectOption('#er-palette', 'P01');
    await page.waitForSelector('#er-karton-wahl', { state: 'visible' });
    await page.click('button:has-text("Starten")'); await page.waitForSelector('#er-run', { state: 'visible' });
    await page.fill('#er-menge', '4');
    await scanne(page, '#er-scan', '4000000000017');
    await page.waitForSelector('#scan-frage', { state: 'visible' });
    await page.click('#scan-frage-ja');
    await page.waitForSelector('#er-status .ok');
    if (!/im Reiter „Abgleich" vermerkt/.test(await page.textContent('#er-status'))) throw new Error('Hinweis fehlt');
    gleich(offen('mehr'), 2, 'Mehrmenge erfasst');
  });

  await test('Abgleich: Quelle inzwischen leer → nur „ohne Buchung erledigen"', async page => {
    szenario();
    sql(`select inventur_anwenden('Regal 4', '{"A1":0}'::jsonb)`);
    await page.click('button[data-t="abgleich"]');
    await page.waitForSelector('.abg-fall');
    if (await page.isVisible('.abg-fall button:has-text("Fehlt wirklich")')) throw new Error('Ausbuchen angeboten, obwohl nichts mehr da ist');
    if (await page.isVisible('.abg-fall button:has-text("Ausgleichen")')) throw new Error('Ausgleichen angeboten, obwohl nichts mehr da ist');
    await page.click('.abg-fall button:has-text("ohne Buchung erledigen")');
    await page.click('#abg-ok');
    await page.waitForSelector('#abg-status .ok');
    gleich(offen('fehlt'), 0, 'Fehlmenge erledigt');
    gleich(menge('A1', 'Regal 4'), 0, 'Bestand unverändert');
  });

  ende();
})();
