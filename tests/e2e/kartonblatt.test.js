// Browser-Tests für das Karton-Blatt (große EAN, Druckränder, lange Kartonnamen).
// Aufruf: NODE_PATH=$(npm root -g) node tests/e2e/kartonblatt.test.js
const { sql, gleich, test, ende } = require('./hilfe');

async function blattOeffnen(page, ctx, name) {
  const fenster = new Promise(r => ctx.once('page', r));
  await page.evaluate(n => kartonBlattDrucken(n), name);
  const w = await fenster;
  await w.waitForSelector('.blatt');
  await w.waitForTimeout(1800);   // Einpassen läuft beim Druckstart
  return w;
}

(async () => {
  await test('Karton-Blatt: EAN groß, letzte 4 Ziffern hervorgehoben', async (page, ctx) => {
    sql("insert into bestaende values ('A2', 'P05-K03', 4), ('SET1', 'P05-K03', 1)");
    const w = await blattOeffnen(page, ctx, 'P05-K03');
    const zellen = await w.$$eval('td.mono', l => l.map(td => ({ html: td.innerHTML, gr: parseFloat(getComputedStyle(td).fontSize),
      grB: td.querySelector('b') ? parseFloat(getComputedStyle(td.querySelector('b')).fontSize) : 0 })));
    gleich(zellen.length, 2, 'Zeilen');
    gleich(zellen.map(z => z.html).sort().join(' | '), '400000000<b>0024</b> | 400000000<b>0031</b>', 'EAN-Aufteilung');
    if (zellen[0].gr < 19 || zellen[0].grB < 24) throw new Error('Schrift zu klein: ' + JSON.stringify(zellen[0]));   // 15pt / 19pt
    const ueber = await w.$$eval('td', l => l.filter(td => td.scrollWidth > td.clientWidth + 1).length);
    gleich(ueber, 0, 'abgeschnittene Zellen');
  });

  await test('Karton-Blatt: Ränder 15 mm, langer Kartonname passt aufs Blatt', async (page, ctx) => {
    sql("insert into bestaende values ('A2', 'Unbekannt-Sammelkarton-01', 4)");
    await page.setViewportSize({ width: 1600, height: 900 });   // breites Druckfenster
    const w = await blattOeffnen(page, ctx, 'Unbekannt-Sammelkarton-01');
    const css = await w.$eval('style', s => s.textContent);
    if (!/@page\{size:A4;margin:15mm;\}/.test(css)) throw new Error('Seitenränder fehlen');
    const m = await w.evaluate(() => {
      const k = document.querySelector('.kopf'), kar = document.querySelector('.kar'), b = document.querySelector('.blatt');
      return { kar: kar.getBoundingClientRect().right, kopf: k.getBoundingClientRect().right, blatt: b.getBoundingClientRect().width,
               mm: document.body.appendChild(Object.assign(document.createElement('div'), { style: 'width:180mm' })).getBoundingClientRect().width };
    });
    if (Math.abs(m.blatt - m.mm) > 1) throw new Error('Blattbreite nicht 180 mm: ' + JSON.stringify(m));
    if (m.kar > m.kopf + 1) throw new Error('Kartonname ragt über das Blatt: ' + JSON.stringify(m));
  });

  ende();
})();
