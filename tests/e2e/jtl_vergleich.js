// Vergleicht jtl_kommentar_csv() (Datenbank, ab Paket 3c) mit der früheren JavaScript-Logik
// der Edge Function. Aufruf nach start.sh + Testdaten: node tests/e2e/jtl_vergleich.js → „GLEICH"
const { execSync } = require('child_process');
const q = s => JSON.parse(execSync(`psql -h /tmp -p 54329 -U postgres -d lp -XAtc "${s}"`).toString() || 'null');
// alte Logik aus index.ts (vor 3c), 1:1 übernommen
function csvZelle(v){let s=v==null?"":String(v);if(/[";\n]/.test(s))s='"'+s.replace(/"/g,'""')+'"';return s;}
function alt(artikelAlle,bestaende){const unb=new Set(artikelAlle.filter(a=>a.unbekannt===1).map(a=>a.artikelnummer));const artikel=artikelAlle.filter(a=>!unb.has(a.artikelnummer));const grp={};for(const r of bestaende){if(!(r.menge>0)||unb.has(r.artikelnummer))continue;(grp[r.artikelnummer]=grp[r.artikelnummer]||[]).push(r.lagerplatz+" ("+r.menge+")");}const alle=[...new Set([...artikel.map(a=>a.artikelnummer),...Object.keys(grp)])].sort();const zeilen=[["Artikelnummer","Kommentar"],...alle.map(nr=>[nr,(grp[nr]||[]).join(", ")])];return {csv:zeilen.map(z=>z.map(csvZelle).join(";")).join("\r\n"),artikel:alle.length,mit_bestand:Object.keys(grp).length};}
const art = q("select coalesce(json_agg(a order by artikelnummer),'[]') from artikel a");
const best = q("select coalesce(json_agg(b order by artikelnummer, lagerplatz),'[]') from bestaende b");
const a = alt(art, best), n = q("select jtl_kommentar_csv()");
console.log(a.csv === n.csv && a.artikel === n.artikel && a.mit_bestand === n.mit_bestand ? 'GLEICH' : 'UNTERSCHIED');
if (a.csv !== n.csv) { console.log(JSON.stringify(a.csv)); console.log(JSON.stringify(n.csv)); }
console.log(a.artikel, n.artikel, a.mit_bestand, n.mit_bestand);
