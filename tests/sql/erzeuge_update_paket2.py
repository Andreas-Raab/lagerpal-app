#!/usr/bin/env python3
# Erzeugt supabase/updates/2026-10_paket2.sql aus 00_KOMPLETT_neu_aufsetzen.sql:
# geänderte Funktionen + neuer Abschnitt „Abgleich", eingerahmt von Kopf/Fuß.
# Prüfung danach: alte DB + Update muss denselben Fingerabdruck haben wie eine
# Neuinstallation (siehe tests/README.md).
import re, pathlib
root = pathlib.Path(__file__).resolve().parents[2]
s = (root / 'supabase/00_KOMPLETT_neu_aufsetzen.sql').read_text(encoding='utf-8')
ziel = root / 'supabase/updates/2026-10_paket2.sql'
u = ziel.read_text(encoding='utf-8')
namen = ['buchen','umlagern','einraeumen_scan','einraeumen_rest_melden','karton_setzen','karton_neu','sammel_ausbuchen',
         'inventur_anwenden','rueckgaengig_eine','rueckgaengig','lagerplatz_umbenennen','lagerplatz_zusammenlegen',
         'lagerplatz_loeschen','bestand_csv_import','alles_loeschen','backup_wiederherstellen','unbekannt_karton_naechster']
def block(name):
    a = re.search(r'create or replace function ' + name + r'\(', s).start()
    nxt = s.find('create or replace function', a + 10)
    ends = [x.end() for x in re.finditer(r'(revoke|grant)[^\n]*function ' + name + r'\([^\n]*\n', s)
            if x.start() > a and (nxt == -1 or x.start() < nxt)]
    return s[a:max(ends)]
abschnitt = s[s.index('-- ─── Abschnitt: Abgleich nach dem Sortieren'):].rstrip() + '\n'
kopf = u[:u.index('create or replace function buchen(')]
fuss = u[u.index('\ncommit;'):]
# Neuer Abschnitt muss VOR den Funktionen stehen, die die Tabelle benutzen? Nein -
# plpgsql löst Tabellen erst zur Laufzeit auf. Er steht hier am Ende.
ziel.write_text(kopf + '\n\n'.join(block(n) for n in namen) + '\n\n' + abschnitt + fuss, encoding='utf-8')
print('geschrieben:', ziel)
