-- Testdaten für die lokalen Tests (NICHT in Supabase ausführen).
insert into artikel (artikelnummer, artikelname, gtin, ist_set, online) values
  ('A1',   'Testartikel Online',  '4000000000017', 0, 1),
  ('A2',   'Testartikel Offline', '4000000000024', 0, 2),
  ('SET1', 'Test-Set',            '4000000000031', 1, 1),
  ('A3',   'Zwei ähnliche Plätze','4000000000048', 0, 1);
insert into bestaende (artikelnummer, lagerplatz, menge) values
  ('A1', 'Regal 3', 12), ('A1', 'Regal 4', 5),
  ('A2', 'QUELLE-1', 10), ('A1', 'QUELLE-1', 2),
  ('SET1', 'Regal 3', 4),
  ('A3', 'Regal-1', 7), ('A3', 'Regal 1', 3),
  ('A2', 'Alt-Platz', 0);
