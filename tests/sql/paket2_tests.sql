-- Datenbank-Tests für Paket 2. Erwartet frische Testdaten (01_testdaten.sql).
-- Jeder Test meldet „OK: …"; ein Fehler bricht mit Meldung ab.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- helper
create or replace function pg_temp.m(a text, l text) returns int language sql as
  $$ select coalesce((select menge from bestaende where artikelnummer=a and lagerplatz=l), 0) $$;
create or replace function pg_temp.letzte() returns bigint language sql as
  $$ select max(id) from buchungen where rueckgaengig_gemacht = 0 $$;

-- 14: Kartonnummer aus der Datenbank, berücksichtigt alte (leere) Kartons
do $$ declare r jsonb; begin
  insert into bestaende values ('A2','P07-K04',0);                         -- alter, leerer Karton
  insert into lagerplaetze (name, palette, kanal) values ('P07-K02','P07',1);
  r := karton_neu('P07', 1);  assert r->>'name' = 'P07-K05', 'erwartet P07-K05, ist ' || (r->>'name');
  r := karton_neu(' P07 ', 2); assert r->>'name' = 'P07-K06', 'erwartet P07-K06, ist ' || (r->>'name');
  assert (select kanal from lagerplaetze where name='P07-K06') = 2;
  r := karton_neu('P.1', 1);  assert r->>'name' = 'P.1-K01', 'Sonderzeichen in Palette: ' || (r->>'name');
  raise notice 'OK: karton_neu vergibt fortlaufende Nummern';
end $$;

-- 21: Einräum-Scan mit Mehrmenge = ein Vorgang, Rückgängig nimmt beides zurück
do $$ declare r jsonb; begin
  perform einraeumen_scan('A1','QUELLE-1','P01-K01',5);     -- 2 umgelagert + 3 Inventur-Zugang
  assert pg_temp.m('A1','P01-K01') = 5 and pg_temp.m('A1','QUELLE-1') = 0;
  r := rueckgaengig(pg_temp.letzte());
  assert (r->>'teile')::int = 2, 'Teile: ' || (r->>'teile');
  assert pg_temp.m('A1','P01-K01') = 0, 'Karton nicht leer: ' || pg_temp.m('A1','P01-K01');
  assert pg_temp.m('A1','QUELLE-1') = 2, 'Quelle nicht zurück: ' || pg_temp.m('A1','QUELLE-1');
  raise notice 'OK: Einräum-Scan wird vollständig zurückgenommen (%)', r->>'beschreibung';
end $$;

-- 17 + 21: Sammel-Ausbuchen = ein Vorgang
do $$ declare r jsonb; begin
  perform sammel_ausbuchen(array['A1','A3']);
  assert pg_temp.m('A1','Regal 3') = 0 and pg_temp.m('A3','Regal-1') = 0;
  r := rueckgaengig(pg_temp.letzte());
  assert (r->>'teile')::int = 5, 'Teile: ' || (r->>'teile');   -- A1: Regal 3, Regal 4, QUELLE-1; A3: 2 Plätze
  assert pg_temp.m('A1','Regal 3') = 12 and pg_temp.m('A1','Regal 4') = 5 and pg_temp.m('A3','Regal-1') = 7 and pg_temp.m('A3','Regal 1') = 3;
  raise notice 'OK: Sammel-Ausbuchen wird komplett zurückgenommen';
end $$;

-- Normale Einzelbuchung: Rückgängig wie bisher genau eine Zeile
do $$ declare r jsonb; begin
  perform buchen('A1','Regal 3','aus',2,'');
  r := rueckgaengig(pg_temp.letzte());
  assert (r->>'teile')::int = 1 and pg_temp.m('A1','Regal 3') = 12;
  raise notice 'OK: Einzelbuchung → ein Teil';
end $$;

-- 18: höchstens eine offene Leermeldung je Artikel + Platz
do $$ declare n int; begin
  perform buchen('A1','Regal 4','aus',5,'');                 -- leer → Meldung
  perform buchen('A1','Regal 4','ein',1,'');                 -- wieder befüllt → Meldung weg
  perform buchen('A1','Regal 4','aus',1,'');                 -- erneut leer → neue Meldung
  -- simuliert das Rennen zweier Geräte: zweite Meldung direkt einfügen
  insert into leermeldungen (zeitstempel, artikelnummer, lagerplatz, gesehen, hinweis)
    values (now(), 'A1', 'Regal 4', 0, '') on conflict do nothing;
  select count(*) into n from leermeldungen where artikelnummer='A1' and lagerplatz='Regal 4' and gesehen=0;
  assert n = 1, 'offene Meldungen: ' || n;
  begin
    insert into leermeldungen (zeitstempel, artikelnummer, lagerplatz, gesehen, hinweis) values (now(), 'A1', 'Regal 4', 0, '');
    raise exception 'Doppelte Meldung wurde NICHT verhindert';
  exception when unique_violation then null; end;
  raise notice 'OK: keine doppelten offenen Leermeldungen';
end $$;

-- 19: Rückgängig „Artikeländerung" trotz geteilter GTIN
do $$ declare r jsonb; begin
  update artikel set gtin = '4000000000017' where artikelnummer = 'A3';   -- A1 und A3 teilen die GTIN
  perform artikel_bearbeiten('A1', 'Neuer Name', '4000000000017', 0, 1);
  r := rueckgaengig(pg_temp.letzte());
  assert (select artikelname from artikel where artikelnummer='A1') = 'Testartikel Online';
  raise notice 'OK: Artikeländerung mit geteilter GTIN rücknehmbar';
end $$;

-- 20: Lagerplatz löschen → Rückgängig stellt Palette/Kanal wieder her
do $$ declare r jsonb; begin
  perform karton_setzen('P09-K01', 'P09', 2);
  perform buchen('A2','P09-K01','ein',3,'');
  perform lagerplatz_loeschen('P09-K01', true);
  r := rueckgaengig(pg_temp.letzte());
  assert (select palette from lagerplaetze where name='P09-K01') = 'P09';
  assert (select kanal from lagerplaetze where name='P09-K01') = 2;
  assert pg_temp.m('A2','P09-K01') = 3;
  raise notice 'OK: gelöschter Karton kommt mit Palette und Kanal zurück';
end $$;

-- 20: Zusammenlegen in neues Ziel → Rückgängig: Palette/Kanal zurück, Ziel weg, leerer Karton wieder da
do $$ declare r jsonb; begin
  perform karton_setzen('P08-K01', 'P08', 1);
  perform karton_setzen('P08-K02', 'P08', 2);                    -- leer, nur Metadaten
  perform buchen('A1','P08-K01','ein',2,'');
  perform lagerplatz_zusammenlegen('["P08-K01","P08-K02"]'::jsonb, 'P08-NEU');
  assert not exists (select 1 from lagerplaetze where name='P08-K02');
  r := rueckgaengig(pg_temp.letzte());
  assert (select kanal from lagerplaetze where name='P08-K01') = 1, 'Kanal K01';
  assert (select palette from lagerplaetze where name='P08-K02') = 'P08', 'leerer Karton K02 fehlt';
  assert (select kanal from lagerplaetze where name='P08-K02') = 2, 'Kanal K02';
  assert not exists (select 1 from lagerplaetze where name='P08-NEU'), 'neues Ziel blieb stehen';
  assert pg_temp.m('A1','P08-K01') = 2;
  raise notice 'OK: Zusammenlegung vollständig zurückgenommen';
end $$;

-- 22: Umbenennung zurücknehmen, wenn der alte Name wieder existiert → verständliche Meldung
do $$ declare r jsonb; begin
  perform lagerplatz_umbenennen('Alt-Platz', 'Neu-Platz-X');
  perform karton_setzen('Alt-Platz', '', 0);     -- schreibt kein Protokoll, blockiert also nicht
  begin
    r := rueckgaengig(pg_temp.letzte());
    raise exception 'hätte scheitern müssen';
  exception when others then
    assert sqlerrm like '%gibt es inzwischen wieder%', 'Meldung: ' || sqlerrm;
  end;
  raise notice 'OK: verständliche Meldung bei Umbenennung';
end $$;

-- Backup einspielen nimmt die Vorgangs-Kennung mit und verträgt doppelte offene Meldungen
do $$ declare r jsonb; v uuid := gen_random_uuid(); begin
  r := backup_wiederherstellen(jsonb_build_object(
    'artikel', jsonb_build_array(jsonb_build_object('artikelnummer','B1','artikelname','x','gtin','','ist_set',0,'online',1)),
    'bestaende', '[]'::jsonb, 'lagerplaetze', '[]'::jsonb,
    'buchungen', jsonb_build_array(jsonb_build_object('id',1,'zeitstempel',now(),'typ','Eingang','artikelnummer','B1','lagerplatz','X','menge',1,'rueckgaengig_gemacht',0,'vorgang',v)),
    'leermeldungen', jsonb_build_array(
        jsonb_build_object('id',1,'zeitstempel',now(),'artikelnummer','B1','lagerplatz','X','gesehen',0,'hinweis',''),
        jsonb_build_object('id',2,'zeitstempel',now(),'artikelnummer','B1','lagerplatz','X','gesehen',0,'hinweis',''))));
  assert (select vorgang from buchungen where id = 1) = v, 'vorgang nicht übernommen';
  assert (select count(*) from leermeldungen where gesehen = 0) = 1;
  raise notice 'OK: Backup einspielen (vorgang, doppelte Meldungen)';
end $$;
