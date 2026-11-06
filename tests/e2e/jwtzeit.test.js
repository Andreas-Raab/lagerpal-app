// „JWT issued at future" (Uhrzeit-Versatz bei Supabase direkt nach dem Anmelden)
// wird automatisch wiederholt statt als Fehler gemeldet.
// Aufruf: NODE_PATH=$(npm root -g) node tests/e2e/jwtzeit.test.js
const { execSync } = require('child_process');
const { BASE, menge, gleich, scanne, test, ende } = require('./hilfe');
const zukunft = n => execSync(`curl -s "${BASE}/__jwtzukunft?n=${n}"`);

(async () => {
  await test('Abgelehnte Anfrage wird wiederholt, Buchung klappt ohne Fehlermeldung', async page => {
    await page.click('button[data-t="buchen"]'); await page.click('#ss-mode-aus');
    zukunft(2);
    await scanne(page, '#ss-scan', '4000000000024');
    await page.waitForSelector('#ss-status .ok, #ss-status .err', { timeout: 15000 });
    if (await page.isVisible('#ss-status .err')) throw new Error(await page.textContent('#ss-status'));
    gleich(menge('A2', 'QUELLE-1'), 9, 'genau einmal gebucht');
    gleich(await page.isVisible('#fehler-toast'), false, 'Fehlermeldung sichtbar');
  });
  await test('Beim Neuladen: keine Fehlermeldung, Suche lädt', async page => {
    zukunft(3);
    await page.reload();
    await page.waitForSelector('.such-table', { timeout: 20000 });
    await page.waitForTimeout(500);
    gleich(await page.isVisible('#fehler-toast'), false, 'Fehlermeldung sichtbar');
  });
  zukunft(0);
  ende();
})();
