-- Datenbank-Tests für den Reiter „Abgleich". Erwartet frische Testdaten (01_testdaten.sql).
\set ON_ERROR_STOP 1
create or replace function pg_temp.m(a text, l text) returns int language sql as
  $$ select coalesce((select menge from bestaende where artikelnummer=a and lagerplatz=l), 0) $$;
create or replace function pg_temp.letzte() returns bigint language sql as
  $$ select max(id) from buchungen where rueckgaengig_gemacht = 0 $$;
create or replace function pg_temp.offen(a text, art_ text) returns int language sql as
  $$ select coalesce(sum(offen),0)::int from mengen_abweichungen where artikelnummer=a and art=art_ $$;

-- Szenario: A1 lag in Wahrheit auf „QUELLE-1" statt auf „Regal 4"
do $$ declare r jsonb; v_mehr bigint; v_fehlt bigint; begin
  perform karton_setzen('P01-K01','P01',1);
  perform einraeumen_scan('A1','QUELLE-1','P01-K01',5);            -- 2 da, 3 zu viel
  assert pg_temp.offen('A1','mehr') = 3, 'Mehrmenge nicht erfasst';
  perform einraeumen_rest_melden('Regal 4','P01');                  -- Regal 4 „sortiert": 5 Stk A1 nicht gefunden
  assert pg_temp.offen('A1','fehlt') = 5, 'Fehlmenge nicht erfasst';
  perform einraeumen_rest_melden('Regal 4','P01');                  -- zweites „Palette fertig": keine Dublette
  assert (select count(*) from mengen_abweichungen where art='fehlt' and artikelnummer='A1') = 1, 'Fehlmenge doppelt';
  raise notice 'OK: Mehr- und Fehlmengen werden beim Sortieren erfasst';

  select id into v_mehr from mengen_abweichungen where art='mehr' and artikelnummer='A1';
  select id into v_fehlt from mengen_abweichungen where art='fehlt' and artikelnummer='A1';
  r := abgleich_buchen('ausgleich', v_mehr, v_fehlt, 3);
  assert pg_temp.m('A1','Regal 4') = 2 and pg_temp.offen('A1','mehr') = 0 and pg_temp.offen('A1','fehlt') = 2, 'Ausgleich falsch';
  assert pg_temp.m('A1','P01-K01') = 5, 'Karton darf sich nicht ändern';
  raise notice 'OK: Ausgleichen (%)', r->>'beschreibung';

  r := rueckgaengig(pg_temp.letzte());
  assert pg_temp.m('A1','Regal 4') = 5 and pg_temp.offen('A1','mehr') = 3 and pg_temp.offen('A1','fehlt') = 5, 'Rückgängig Ausgleich falsch';
  raise notice 'OK: Ausgleich rückgängig';

  r := abgleich_buchen('verlust', null, v_fehlt, 2);
  assert pg_temp.m('A1','Regal 4') = 3 and pg_temp.offen('A1','fehlt') = 3;
  assert (select typ from buchungen where id = pg_temp.letzte()) = 'Inventurdifferenz';
  r := rueckgaengig(pg_temp.letzte());
  assert pg_temp.m('A1','Regal 4') = 5 and pg_temp.offen('A1','fehlt') = 5;
  raise notice 'OK: Inventurdifferenz + Rückgängig';

  r := abgleich_buchen('neu', v_mehr, null, 3);
  assert pg_temp.offen('A1','mehr') = 0 and pg_temp.m('A1','P01-K01') = 5;
  r := rueckgaengig(pg_temp.letzte());
  assert pg_temp.offen('A1','mehr') = 3;
  raise notice 'OK: Neufund + Rückgängig';

  begin perform abgleich_buchen('ausgleich', v_mehr, v_fehlt, 4); raise exception 'zu viel erlaubt';
  exception when others then assert sqlerrm like '%nur noch 3 Stk offen%', sqlerrm; end;
  raise notice 'OK: Mengen werden geprüft';
end $$;

-- Rückgängig des Einräum-Scans entfernt dessen Mehrmenge
do $$ declare r jsonb; begin
  delete from mengen_abweichungen;
  perform einraeumen_scan('A2','QUELLE-1','P01-K01',12);             -- 10 da, 2 zu viel
  assert pg_temp.offen('A2','mehr') = 2;
  r := rueckgaengig(pg_temp.letzte());
  assert not exists (select 1 from mengen_abweichungen where artikelnummer='A2'), 'Mehrmenge blieb stehen';
  raise notice 'OK: Rückgängig des Scans entfernt die Mehrmenge';
end $$;

-- Ansicht liefert Name und Gesamtbestand
do $$ begin
  perform einraeumen_rest_melden('Regal 3','P01');
  assert (select gesamtbestand from v_abgleich where artikelnummer='A1' and art='fehlt' limit 1)
         = (select sum(menge) from bestaende where artikelnummer='A1'), 'Gesamtbestand falsch: ' ||
     (select gesamtbestand from v_abgleich where artikelnummer='A1' and art='fehlt' limit 1);
  assert (select artikelname from v_abgleich where artikelnummer='A1' limit 1) = 'Testartikel Online';
  raise notice 'OK: v_abgleich';
end $$;

-- ── Review-Funde ──
truncate buchungen, leermeldungen, bestaende, lagerplaetze, artikel, mengen_abweichungen restart identity cascade;
\ir 01_testdaten.sql

-- 1: Fehlmenge ohne Buchung erledigen; Quelle inzwischen leer → bei erneutem „fertig" automatisch zu
do $$ declare r jsonb; v_f bigint; begin
  perform einraeumen_rest_melden('Regal 4','P01');                       -- A1: 5 fehlen
  select id into v_f from mengen_abweichungen where art='fehlt' and artikelnummer='A1';
  r := abgleich_buchen('erledigt', null, v_f, 2);
  assert pg_temp.offen('A1','fehlt') = 3 and pg_temp.m('A1','Regal 4') = 5, 'erledigt darf Bestand nicht ändern';
  r := rueckgaengig(pg_temp.letzte());
  assert pg_temp.offen('A1','fehlt') = 5;
  perform inventur_anwenden('Regal 4', '{"A1":0}'::jsonb);                -- Quelle per Inventur geleert
  perform einraeumen_rest_melden('Regal 4','P01');
  assert pg_temp.offen('A1','fehlt') = 0, 'verwaiste Fehlmenge nicht geschlossen';
  raise notice 'OK: ohne Buchung erledigen / verwaiste Fehlmenge';
end $$;

-- 5: erneutes „Palette fertig" nach Teil-Erledigung - Rückgängig stimmt weiter
do $$ declare r jsonb; v_f bigint; v_id bigint; begin
  delete from mengen_abweichungen;
  perform einraeumen_rest_melden('Regal 3','P01');                        -- A1: 12 fehlen
  select id into v_f from mengen_abweichungen where art='fehlt' and artikelnummer='A1' and quelle='Regal 3';
  r := abgleich_buchen('verlust', null, v_f, 6);  v_id := pg_temp.letzte();  -- 6 ausgebucht, 6 offen
  perform einraeumen_rest_melden('Regal 3','P01');                        -- erneut fertig
  r := rueckgaengig(v_id);
  assert pg_temp.m('A1','Regal 3') = 12 and pg_temp.offen('A1','fehlt') = 12, 'offen nach Rückgängig: ' || pg_temp.offen('A1','fehlt');
  raise notice 'OK: erneutes Palette fertig + Rückgängig';
end $$;

-- 2: Umbenennen zieht Fälle mit, Rückgängig wieder zurück
do $$ declare r jsonb; begin
  perform lagerplatz_umbenennen('Regal 3','Regal Drei');
  assert exists (select 1 from mengen_abweichungen where quelle='Regal Drei');
  r := rueckgaengig(pg_temp.letzte());
  assert exists (select 1 from mengen_abweichungen where quelle='Regal 3') and not exists (select 1 from mengen_abweichungen where quelle='Regal Drei');
  raise notice 'OK: Umbenennen + Rückgängig';
end $$;

-- 7: Ausgleich ist kein Warenausgang
do $$ declare r jsonb; v_m bigint; v_f bigint; begin
  delete from mengen_abweichungen;
  perform karton_setzen('P01-K01','P01',1);
  perform einraeumen_scan('A1','QUELLE-1','P01-K01',5);
  perform einraeumen_rest_melden('Regal 3','P01');
  select id into v_m from mengen_abweichungen where art='mehr'; select id into v_f from mengen_abweichungen where art='fehlt' and quelle='Regal 3';
  r := abgleich_buchen('ausgleich', v_m, v_f, 3);
  assert (select typ from buchungen where id = pg_temp.letzte()) = 'Ausgleich';
  assert (select coalesce(aus_heute,0) from v_dashboard) = 0, 'Ausgleich zählt als Ausgang';
  r := rueckgaengig(pg_temp.letzte());
  assert pg_temp.m('A1','Regal 3') = 12;
  raise notice 'OK: Ausgleich eigener Typ, nicht im Warenausgang';
end $$;

-- 3: Backup einspielen übernimmt/leert Fälle, Alles löschen leert sie
do $$ declare r jsonb; begin
  r := backup_wiederherstellen(jsonb_build_object('artikel','[]'::jsonb,'bestaende','[]'::jsonb,'lagerplaetze','[]'::jsonb,'buchungen','[]'::jsonb,'leermeldungen','[]'::jsonb));
  assert not exists (select 1 from mengen_abweichungen), 'alte Fälle nach Backup ohne Fälle';
  r := backup_wiederherstellen(jsonb_build_object('artikel','[]'::jsonb,'bestaende','[]'::jsonb,'lagerplaetze','[]'::jsonb,'buchungen','[]'::jsonb,'leermeldungen','[]'::jsonb,
       'mengen_abweichungen', jsonb_build_array(jsonb_build_object('id',7,'art','fehlt','artikelnummer','X','menge',3,'offen',2,'quelle','Q'))));
  assert (select offen from mengen_abweichungen where id=7) = 2, 'Fall aus Backup fehlt';
  perform alles_loeschen('ALLES LOESCHEN');
  assert not exists (select 1 from mengen_abweichungen), 'Alles löschen lässt Fälle stehen';
  raise notice 'OK: Backup/Reset';
end $$;
