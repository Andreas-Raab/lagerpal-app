-- ═══════════════════════════════════════════════════════════════════════
-- LagerPal – UPDATE Paket 2 (Stand 10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Für ein BESTEHENDES System (Daten bleiben erhalten). Im Supabase SQL-Editor
-- komplett einfügen und ausführen. Kann gefahrlos mehrfach ausgeführt werden.
-- ZUERST im Testsystem, dann im echten System - und zwar BEVOR die neue
-- index.html live geht (die alte App läuft mit diesem Update unverändert weiter).
--
-- Kontrolle danach: tests/sql/fingerabdruck.sql muss im Test- und im echten
-- System denselben Wert liefern wie eine Neuinstallation mit
-- 00_KOMPLETT_neu_aufsetzen.sql (dort sind dieselben Änderungen enthalten).
--
-- Inhalt:
--  • buchungen.vorgang: zusammengehörende Buchungen; Rückgängig nimmt den ganzen
--    Vorgang zurück (Einräum-Scan mit Mehrmenge, Sammel-Ausbuchen)
--  • höchstens eine offene Leermeldung je Artikel + Platz (Doppelte → gesehen)
--  • karton_neu(): Kartonnummer wird in der Datenbank vergeben (mehrere Geräte)
--  • Sammel-Ausbuchen sperrt die Zeilen (protokollierte = ausgebuchte Menge)
--  • Rückgängig: keine GTIN-Sperre mehr; Palette/Kanal nach Zusammenlegen/Löschen
--    wieder da; verständliche Meldung bei Umbenennung
--  • Kartonnummern (auch Unbekannt-NN) ab 100 nicht mehr abgeschnitten
--  • Setup-Skript wiederholbar (betrifft nur 00_KOMPLETT…)
-- ═══════════════════════════════════════════════════════════════════════

begin;

alter table buchungen add column if not exists vorgang uuid;
create index if not exists idx_buchungen_vorgang on buchungen(vorgang) where vorgang is not null;

update leermeldungen l set gesehen = 1
    where gesehen = 0 and artikelnummer <> '—'
      and exists (select 1 from leermeldungen k where k.gesehen = 0 and k.artikelnummer = l.artikelnummer
                  and k.lagerplatz = l.lagerplatz and k.id < l.id);
create unique index if not exists uq_leer_offen on leermeldungen(artikelnummer, lagerplatz)
    where gesehen = 0 and artikelnummer <> '—';

create or replace function buchen(
    p_artikelnummer text,
    p_lagerplatz    text,
    p_typ           text,              -- 'ein' | 'aus'
    p_menge         integer,
    p_kommentar     text default ''
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
    v_name  text;
    v_gtin  text;
    v_delta integer;
    v_lp_vorher      integer;
    v_lp_nachher     integer;
    v_gesamt_vorher  integer;
    v_gesamt_nachher integer;
begin
    if p_typ not in ('ein','aus') then raise exception 'Ungültiger Typ'; end if;
    if p_menge is null or p_menge <= 0 then raise exception 'Menge muss eine positive ganze Zahl sein'; end if;

    select artikelname, gtin into v_name, v_gtin from artikel where artikelnummer = p_artikelnummer;
    if not found then raise exception 'Artikel % nicht gefunden', p_artikelnummer; end if;

    v_delta := case when p_typ = 'ein' then p_menge else -p_menge end;

    if p_typ = 'ein' then
        -- Bestand am Platz atomar erhöhen (race-sicher, kein Lost-Update)
        insert into bestaende (artikelnummer, lagerplatz, menge)
            values (p_artikelnummer, p_lagerplatz, p_menge)
            on conflict (artikelnummer, lagerplatz)
            do update set menge = bestaende.menge + p_menge
            returning menge into v_lp_nachher;
    else
        -- nur abziehen, wenn genug da ist; die Bedingung wird unter Zeilensperre
        -- ausgewertet, zwei gleichzeitige Ausgänge können also nicht beide durchgehen
        update bestaende set menge = menge - p_menge
            where artikelnummer = p_artikelnummer and lagerplatz = p_lagerplatz and menge >= p_menge
            returning menge into v_lp_nachher;
        if not found then
            select menge into v_lp_vorher from bestaende
                where artikelnummer = p_artikelnummer and lagerplatz = p_lagerplatz;
            raise exception 'Bestand auf % würde negativ (aktuell: %)', p_lagerplatz, coalesce(v_lp_vorher, 0);
        end if;
    end if;
    v_lp_vorher := v_lp_nachher - v_delta;

    select coalesce(sum(menge),0) into v_gesamt_nachher from bestaende where artikelnummer = p_artikelnummer;
    v_gesamt_vorher := v_gesamt_nachher - v_delta;

    insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
        bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar)
        values (now(), case when p_typ='ein' then 'Eingang' else 'Ausgang' end,
            p_artikelnummer, v_name, v_gtin, p_lagerplatz, p_menge,
            v_lp_vorher, v_lp_nachher, v_gesamt_vorher, v_gesamt_nachher, p_kommentar);

    -- Glocke pflegen: leer geworden → melden (nur wenn keine offene Meldung existiert)
    if v_lp_vorher > 0 and v_lp_nachher = 0 then
        if not exists (select 1 from leermeldungen
                       where artikelnummer = p_artikelnummer and lagerplatz = p_lagerplatz and gesehen = 0) then
            insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
                values (now(), p_artikelnummer, v_name, v_gtin, p_lagerplatz, 0, '') on conflict do nothing;
        end if;
    end if;
    -- wieder aufgefüllt → offene Meldung entfernen
    if p_typ = 'ein' and v_lp_nachher > 0 then
        delete from leermeldungen
            where artikelnummer = p_artikelnummer and lagerplatz = p_lagerplatz and gesehen = 0;
    end if;

    return jsonb_build_object('ok', true,
        'lp_bestand_neu', v_lp_nachher, 'bestand_gesamt_neu', v_gesamt_nachher,
        'artikelname', v_name);
end;
$$;
revoke all on function buchen(text,text,text,integer,text) from anon, public;
grant execute on function buchen(text,text,text,integer,text) to authenticated;


create or replace function umlagern(
    p_artikelnummer text,
    p_von           text,
    p_nach          text,
    p_menge         integer
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
    v_name text; v_gtin text;
    v_von_vorher  integer;
    v_von_nachher integer;
    v_nach_nachher integer;
begin
    if p_menge is null or p_menge <= 0 then raise exception 'Menge muss eine positive ganze Zahl sein'; end if;
    if p_von = p_nach then raise exception 'Quelle und Ziel sind identisch'; end if;

    select artikelname, gtin into v_name, v_gtin from artikel where artikelnummer = p_artikelnummer;
    if not found then raise exception 'Artikel % nicht gefunden', p_artikelnummer; end if;

    select menge into v_von_vorher from bestaende
        where artikelnummer = p_artikelnummer and lagerplatz = p_von for update;
    if not found then v_von_vorher := 0; end if;
    if v_von_vorher < p_menge then
        raise exception 'Auf % liegen nur % Stk', p_von, v_von_vorher;
    end if;

    -- Ziel atomar erhöhen
    insert into bestaende (artikelnummer, lagerplatz, menge) values (p_artikelnummer, p_nach, p_menge)
        on conflict (artikelnummer, lagerplatz) do update set menge = bestaende.menge + p_menge
        returning menge into v_nach_nachher;

    -- Quelle verringern
    update bestaende set menge = menge - p_menge
        where artikelnummer = p_artikelnummer and lagerplatz = p_von
        returning menge into v_von_nachher;

    -- Glocke pflegen
    if v_von_vorher > 0 and v_von_nachher = 0 then
        if not exists (select 1 from leermeldungen
                       where artikelnummer = p_artikelnummer and lagerplatz = p_von and gesehen = 0) then
            insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
                values (now(), p_artikelnummer, v_name, v_gtin, p_von, 0, '') on conflict do nothing;
        end if;
    end if;
    if v_nach_nachher > 0 then
        delete from leermeldungen where artikelnummer = p_artikelnummer and lagerplatz = p_nach and gesehen = 0;
    end if;

    insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
        bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar)
        values (now(), 'Umlagerung', p_artikelnummer, v_name, v_gtin, p_von || ' → ' || p_nach, p_menge,
            v_von_vorher, v_von_nachher, null, null,
            'MOVE|' || json_build_object('artnr', p_artikelnummer, 'von', p_von, 'nach', p_nach, 'menge', p_menge)::text);

    return jsonb_build_object('ok', true,
        'von_nachher', v_von_nachher, 'nach_nachher', v_nach_nachher, 'artikelname', v_name);
end;
$$;

revoke all on function umlagern(text,text,text,integer) from anon, public;
grant execute on function umlagern(text,text,text,integer) to authenticated;


create or replace function einraeumen_scan(
    p_artikelnummer text,
    p_quelle        text,
    p_ziel          text,
    p_menge         integer
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
    v_name text; v_gtin text;
    v_von_vorher  integer;
    v_von_nachher integer;
    v_ziel_nachher integer;
    v_verf integer;
    v_surplus integer;
    v_vorgang uuid := gen_random_uuid();   -- Umlagerung + Inventur-Zugang = ein Vorgang
begin
    if p_menge is null or p_menge <= 0 then raise exception 'Menge muss eine positive ganze Zahl sein'; end if;
    if p_quelle = p_ziel then raise exception 'Quelle und Ziel sind identisch'; end if;

    select artikelname, gtin into v_name, v_gtin from artikel where artikelnummer = p_artikelnummer;
    if not found then raise exception 'Artikel % nicht gefunden', p_artikelnummer; end if;

    select menge into v_von_vorher from bestaende
        where artikelnummer = p_artikelnummer and lagerplatz = p_quelle for update;
    if not found then v_von_vorher := 0; end if;
    v_von_nachher := v_von_vorher;

    v_verf    := least(v_von_vorher, p_menge);
    v_surplus := p_menge - v_verf;

    select coalesce(menge,0) into v_ziel_nachher from bestaende
        where artikelnummer = p_artikelnummer and lagerplatz = p_ziel;
    v_ziel_nachher := coalesce(v_ziel_nachher, 0);

    if v_verf > 0 then
        insert into bestaende (artikelnummer, lagerplatz, menge) values (p_artikelnummer, p_ziel, v_verf)
            on conflict (artikelnummer, lagerplatz) do update set menge = bestaende.menge + v_verf
            returning menge into v_ziel_nachher;
        update bestaende set menge = menge - v_verf
            where artikelnummer = p_artikelnummer and lagerplatz = p_quelle
            returning menge into v_von_nachher;
        insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar, vorgang)
            values (now(), 'Umlagerung', p_artikelnummer, v_name, v_gtin, p_quelle || ' → ' || p_ziel, v_verf,
                v_von_vorher, v_von_nachher, null, null,
                'MOVE|' || json_build_object('artnr', p_artikelnummer, 'von', p_quelle, 'nach', p_ziel, 'menge', v_verf)::text, v_vorgang);
    end if;

    if v_surplus > 0 then
        insert into bestaende (artikelnummer, lagerplatz, menge) values (p_artikelnummer, p_ziel, v_surplus)
            on conflict (artikelnummer, lagerplatz) do update set menge = bestaende.menge + v_surplus
            returning menge into v_ziel_nachher;
        insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, kommentar, vorgang)
            values (now(), 'Eingang', p_artikelnummer, v_name, v_gtin, p_ziel, v_surplus,
                v_ziel_nachher - v_surplus, v_ziel_nachher, 'Inventur-Zugang (Einräumen)', v_vorgang);
    end if;

    -- Glocke pflegen: Quelle leer geworden → melden; Ziel wieder befüllt → Meldung weg
    if v_von_vorher > 0 and v_von_nachher = 0 then
        if not exists (select 1 from leermeldungen
                       where artikelnummer = p_artikelnummer and lagerplatz = p_quelle and gesehen = 0) then
            insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
                values (now(), p_artikelnummer, v_name, v_gtin, p_quelle, 0, '') on conflict do nothing;
        end if;
    end if;
    if v_ziel_nachher > 0 then
        delete from leermeldungen where artikelnummer = p_artikelnummer and lagerplatz = p_ziel and gesehen = 0;
    end if;

    return jsonb_build_object('ok', true, 'verf_bewegt', v_verf, 'surplus_gebucht', v_surplus,
        'von_nachher', v_von_nachher, 'ziel_nachher', v_ziel_nachher, 'artikelname', v_name);
end;
$$;
revoke all on function einraeumen_scan(text,text,text,integer) from anon, public;
grant execute on function einraeumen_scan(text,text,text,integer) to authenticated;


create or replace function einraeumen_rest_melden(p_quelle text, p_palette text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_n integer; v_stk integer; v_txt text;
begin
    select count(*), coalesce(sum(menge),0) into v_n, v_stk
        from bestaende where lagerplatz = p_quelle and menge > 0;
    if v_n > 0 then
        v_txt := 'Einräumen Palette ' || coalesce(nullif(p_palette,''),'?')
              || ': auf „' || p_quelle || '" waren nach dem Einräumen noch '
              || v_n || ' Artikel / ' || v_stk || ' Stück gebucht, aber nicht gefunden (stehen gelassen).';
        insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
            values (now(), '—', '', '', p_quelle, 0, v_txt) on conflict do nothing;
    end if;
    return jsonb_build_object('ok', true, 'rest_artikel', v_n, 'rest_stueck', v_stk);
end;
$$;
revoke all on function einraeumen_rest_melden(text,text) from anon, public;
grant execute on function einraeumen_rest_melden(text,text) to authenticated;


create or replace function karton_setzen(p_name text, p_palette text, p_kanal integer)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
    p_name := trim(p_name);
    if p_name is null or p_name = '' then raise exception 'Kein Karton angegeben'; end if;
    if coalesce(p_kanal,0) not in (0,1,2) then raise exception 'Ungültiger Kanal'; end if;
    insert into lagerplaetze (name, angelegt, palette, kanal)
        values (p_name, now()::text, coalesce(p_palette,''), coalesce(p_kanal,0))
        on conflict (name) do update set palette = excluded.palette, kanal = excluded.kanal;
    return jsonb_build_object('ok', true, 'name', p_name,
        'palette', coalesce(p_palette,''), 'kanal', coalesce(p_kanal,0));
end;
$$;
revoke all on function karton_setzen(text,text,integer) from anon, public;
grant execute on function karton_setzen(text,text,integer) to authenticated;


create or replace function karton_neu(p_palette text, p_kanal integer)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_praefix text; v_max integer; v_name text;
begin
    p_palette := trim(p_palette);
    if p_palette is null or p_palette = '' then raise exception 'Keine Palette angegeben'; end if;
    if coalesce(p_kanal,0) not in (0,1,2) then raise exception 'Ungültiger Kanal'; end if;
    perform pg_advisory_xact_lock(hashtext('karton_neu|' || p_palette));
    -- höchste Nummer „<Palette>-K<Zahl>" über Lagerplätze UND Bestände (auch alte, leere)
    v_praefix := p_palette || '-K';
    select coalesce(max(substr(n, length(v_praefix) + 1)::integer), 0) into v_max
        from (select name as n from lagerplaetze union select lagerplatz from bestaende) x
        where left(n, length(v_praefix)) = v_praefix
          and substr(n, length(v_praefix) + 1) ~ '^[0-9]{1,9}$';
    -- mindestens zweistellig, aber ab 100 nicht abschneiden (lpad würde kürzen)
    v_name := p_palette || '-K' || lpad((v_max + 1)::text, greatest(2, length((v_max + 1)::text)), '0');
    insert into lagerplaetze (name, angelegt, palette, kanal)
        values (v_name, now()::text, p_palette, coalesce(p_kanal,0));
    return jsonb_build_object('ok', true, 'name', v_name, 'palette', p_palette, 'kanal', coalesce(p_kanal,0));
end;
$$;
revoke all on function karton_neu(text,integer) from anon, public;
grant execute on function karton_neu(text,integer) to authenticated;


create or replace function sammel_ausbuchen(p_artikelnummern text[])
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
    r record; v_name text; v_gtin text;
    v_stueck integer := 0; v_plaetze integer := 0;
    v_vorgang uuid := gen_random_uuid();
begin
    if p_artikelnummern is null or array_length(p_artikelnummern,1) is null then
        raise exception 'Keine Artikel ausgewählt';
    end if;
    for r in select artikelnummer, lagerplatz, menge from bestaende
             where artikelnummer = any(p_artikelnummern) and menge > 0
             order by artikelnummer, lagerplatz
             for update   -- gelesene Menge = tatsächlich ausgebuchte Menge (kein Zwischenbuchen)
    loop
        select artikelname, gtin into v_name, v_gtin from artikel where artikelnummer = r.artikelnummer;
        update bestaende set menge = 0 where artikelnummer = r.artikelnummer and lagerplatz = r.lagerplatz;
        insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, kommentar, vorgang)
            values (now(), 'Ausgang', r.artikelnummer, v_name, v_gtin, r.lagerplatz, r.menge,
                    r.menge, 0, 'Sammel-Ausbuchen (Suche)', v_vorgang);
        if not exists (select 1 from leermeldungen where artikelnummer=r.artikelnummer and lagerplatz=r.lagerplatz and gesehen=0) then
            insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
                values (now(), r.artikelnummer, v_name, v_gtin, r.lagerplatz, 0, 'Sammel-Ausbuchen') on conflict do nothing;
        end if;
        v_stueck := v_stueck + r.menge;
        v_plaetze := v_plaetze + 1;
    end loop;
    return jsonb_build_object('ok', true, 'artikel', array_length(p_artikelnummern,1), 'stueck', v_stueck, 'plaetze', v_plaetze);
end; $$;
revoke all on function sammel_ausbuchen(text[]) from anon, public;
grant execute on function sammel_ausbuchen(text[]) to authenticated;


create or replace function inventur_anwenden(p_lagerplatz text, p_zaehlungen jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
    r record; v_artnr text; v_ist integer; v_vorher integer;
    v_gesamt_vorher integer; v_gesamt_nachher integer; v_diff integer;
    v_name text; v_gtin text; v_anzahl integer := 0;
begin
    if p_lagerplatz is null or trim(p_lagerplatz) = '' then raise exception 'Kein Lagerplatz angegeben'; end if;
    for r in select key as artnr, value as wert from jsonb_each_text(p_zaehlungen) loop
        v_artnr := trim(r.artnr);
        begin v_ist := r.wert::integer; exception when others then continue; end;
        if v_artnr = '' or v_ist < 0 then continue; end if;
        select artikelname, gtin into v_name, v_gtin from artikel where artikelnummer = v_artnr;
        if not found then continue; end if;
        select menge into v_vorher from bestaende where artikelnummer = v_artnr and lagerplatz = p_lagerplatz;
        if not found then v_vorher := 0; end if;
        if v_ist = v_vorher then continue; end if;
        select coalesce(sum(menge),0) into v_gesamt_vorher from bestaende where artikelnummer = v_artnr;
        insert into bestaende (artikelnummer, lagerplatz, menge) values (v_artnr, p_lagerplatz, v_ist)
            on conflict (artikelnummer, lagerplatz) do update set menge = excluded.menge;
        v_diff := v_ist - v_vorher;
        v_gesamt_nachher := v_gesamt_vorher + v_diff;
        insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar)
            values (now(), 'Inventur', v_artnr, v_name, v_gtin, p_lagerplatz, abs(v_diff),
                v_vorher, v_ist, v_gesamt_vorher, v_gesamt_nachher,
                'Inventur: ' || case when v_diff > 0 then '+' else '' end || v_diff || ' (gezählt ' || v_ist || ')');
        if v_vorher > 0 and v_ist = 0 then
            if not exists (select 1 from leermeldungen where artikelnummer = v_artnr and lagerplatz = p_lagerplatz and gesehen = 0) then
                insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
                    values (now(), v_artnr, v_name, v_gtin, p_lagerplatz, 0, '') on conflict do nothing;
            end if;
        elsif v_ist > 0 then
            delete from leermeldungen where artikelnummer = v_artnr and lagerplatz = p_lagerplatz and gesehen = 0;
        end if;
        v_anzahl := v_anzahl + 1;
    end loop;
    return jsonb_build_object('ok', true, 'lagerplatz', p_lagerplatz, 'anzahl_geaendert', v_anzahl);
end;
$$;
revoke all on function inventur_anwenden(text,jsonb) from anon, public;
grant execute on function inventur_anwenden(text,jsonb) to authenticated;


create or replace function rueckgaengig_eine(p_buchung_id bigint)
returns text
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
    v_max_alter constant interval := interval '2 hours';   -- hier anpassen, falls gewünscht
    b record; info jsonb; v_cur integer; v_neu integer; v_beschr text;
    m_artnr text; m_von text; m_nach text; m_menge integer;
begin
    if p_buchung_id is null then
        raise exception 'Keine Aktion angegeben';
    end if;

    -- 1) Erst sperren, dann prüfen
    select * into b from buchungen where id = p_buchung_id for update;
    if not found then
        raise exception 'VERALTET: Diese Aktion existiert nicht mehr. Bitte Leiste aktualisieren.';
    end if;
    if b.rueckgaengig_gemacht <> 0 then
        raise exception 'VERALTET: Diese Aktion wurde bereits rückgängig gemacht.';
    end if;
    if b.typ not in ('Eingang','Ausgang','Umlagerung','Artikeländerung',
                     'Lagerplatz angelegt','Lagerplatz gelöscht','Umbenennung','Zusammenlegung') then
        raise exception 'Aktionen vom Typ „%" können nicht rückgängig gemacht werden.', b.typ;
    end if;

    -- 2) Jede neuere, nicht zurückgenommene Buchung blockiert (egal welcher Typ).
    --    'Rückgängig'-Einträge selbst tragen rueckgaengig_gemacht = 1 und zählen nicht.
    if exists (select 1 from buchungen where id > p_buchung_id and rueckgaengig_gemacht = 0) then
        raise exception 'VERALTET: Inzwischen gab es eine neuere Aktion (z. B. Buchung, Import oder Inventur). Rückgängig ist nicht mehr möglich — bitte Leiste aktualisieren.';
    end if;

    -- 3) Altersgrenze
    if b.zeitstempel < now() - v_max_alter then
        raise exception 'Aktion ist älter als % — bitte über Protokoll bzw. Inventur korrigieren.', v_max_alter;
    end if;

    if b.typ = 'Lagerplatz angelegt' then
        if exists (select 1 from bestaende where lagerplatz=b.lagerplatz and menge>0) then
            raise exception 'Rückgängig nicht möglich — auf „%" liegt inzwischen Bestand', b.lagerplatz;
        end if;
        delete from bestaende where lagerplatz=b.lagerplatz;
        delete from lagerplaetze where name=b.lagerplatz;
        v_beschr := 'Anlegen rückgängig: Lagerplatz '||b.lagerplatz||' entfernt';

    elsif b.typ = 'Lagerplatz gelöscht' then
        if b.kommentar is null or left(b.kommentar,7) <> 'DELETE|' then raise exception 'Rückgängig nicht möglich (Daten fehlen)'; end if;
        info := substr(b.kommentar, 8)::jsonb;   -- {platz, snap:{artnr:menge}}
        m_von := info->>'platz';
        if exists (select 1 from bestaende where lagerplatz=m_von) or exists (select 1 from lagerplaetze where name=m_von) then
            raise exception 'Rückgängig nicht möglich — „%" existiert bereits wieder', m_von;
        end if;
        declare r2 record;
        begin
            for r2 in select key as artnr, value::integer as m from jsonb_each_text(info->'snap') loop
                insert into bestaende (artikelnummer, lagerplatz, menge) values (r2.artnr, m_von, r2.m)
                    on conflict (artikelnummer, lagerplatz) do update set menge = excluded.menge;
            end loop;
        end;
        -- Palette/Kanal aus dem Snapshot (ältere Einträge haben ihn noch nicht)
        insert into lagerplaetze (name, angelegt, palette, kanal)
            values (m_von, coalesce(info->'lp'->>'angelegt', now()::text),
                    coalesce(info->'lp'->>'palette', ''), coalesce((info->'lp'->>'kanal')::smallint, 0))
            on conflict (name) do nothing;
        v_beschr := 'Löschung rückgängig: Lagerplatz '||m_von||' wiederhergestellt';

    elsif b.typ = 'Umbenennung' then
        if b.kommentar is null or left(b.kommentar,7) <> 'RENAME|' then raise exception 'Rückgängig nicht möglich (Daten fehlen)'; end if;
        info := substr(b.kommentar, 8)::jsonb;   -- {alt, neu}
        m_von := info->>'alt'; m_nach := info->>'neu';
        if exists (select 1 from lagerplaetze where name=m_von) or exists (select 1 from bestaende where lagerplatz=m_von) then
            raise exception 'Rückgängig nicht möglich — „%" gibt es inzwischen wieder', m_von;
        end if;
        update bestaende     set lagerplatz=m_von where lagerplatz=m_nach;
        update leermeldungen set gesehen = 1 where gesehen = 0 and lagerplatz = m_von
            and artikelnummer in (select artikelnummer from leermeldungen where gesehen = 0 and lagerplatz = m_nach);
        update leermeldungen set lagerplatz=m_von where lagerplatz=m_nach;
        update lagerplaetze  set name=m_von       where name=m_nach;
        v_beschr := 'Umbenennung rückgängig: '||m_nach||' → '||m_von;

    elsif b.typ = 'Zusammenlegung' then
        if b.kommentar is null or left(b.kommentar,6) <> 'MERGE|' then raise exception 'Rückgängig nicht möglich (Daten fehlen)'; end if;
        info := substr(b.kommentar, 7)::jsonb;   -- {ziel, snap:{platz:{artnr:menge}}}
        m_nach := info->>'ziel';
        delete from bestaende where lagerplatz = m_nach;
        declare r3 record; r4 record;
        begin
            for r3 in select key as platz, value as arts from jsonb_each(info->'snap') loop
                for r4 in select key as artnr, value::integer as m from jsonb_each_text(r3.arts) loop
                    insert into bestaende (artikelnummer, lagerplatz, menge) values (r4.artnr, r3.platz, r4.m)
                        on conflict (artikelnummer, lagerplatz) do update set menge = excluded.menge;
                end loop;
            end loop;
        end;
        -- Platz-Einstellungen (Palette/Kanal) der Quellen wiederherstellen
        if jsonb_typeof(info->'lp') = 'array' then
            insert into lagerplaetze (name, angelegt, palette, kanal)
                select name, coalesce(angelegt, now()::text), coalesce(palette, ''), coalesce(kanal, 0)
                from jsonb_to_recordset(info->'lp') as x(name text, angelegt text, palette text, kanal smallint)
                on conflict (name) do update set palette = excluded.palette, kanal = excluded.kanal;
        end if;
        -- wurde das Ziel erst durch die Zusammenlegung angelegt, wieder entfernen
        if coalesce((info->>'ziel_neu')::boolean, false)
           and not exists (select 1 from jsonb_object_keys(info->'snap') k where k = m_nach) then
            delete from lagerplaetze where name = m_nach;
            update leermeldungen set gesehen = 1 where lagerplatz = m_nach and gesehen = 0;
        end if;
        v_beschr := 'Zusammenlegung rückgängig: '||m_nach||' aufgeteilt';

    elsif b.typ = 'Artikeländerung' then
        if b.kommentar is null or left(b.kommentar,8) <> 'ARTEDIT|' then raise exception 'Rückgängig nicht möglich (Daten fehlen)'; end if;
        info := substr(b.kommentar, 9)::jsonb;
        -- (keine GTIN-Prüfung mehr: mehrere Artikel dürfen dieselbe GTIN haben)
        update artikel set
            artikelname = coalesce(info->'alt'->>'name',''),
            gtin        = coalesce(info->'alt'->>'gtin',''),
            ist_set     = coalesce((info->'alt'->>'ist_set')::int,0),
            online      = coalesce((info->'alt'->>'online')::int,0)
          where artikelnummer = b.artikelnummer;
        v_beschr := 'Artikeländerung rückgängig: ' || b.artikelnummer;

    elsif b.typ = 'Umlagerung' then
        if b.kommentar is null or left(b.kommentar,5) <> 'MOVE|' then raise exception 'Rückgängig nicht möglich (Daten fehlen)'; end if;
        info := substr(b.kommentar, 6)::jsonb;
        m_artnr := info->>'artnr'; m_von := info->>'von'; m_nach := info->>'nach'; m_menge := (info->>'menge')::int;
        -- relativ vom Ziel abziehen, danach auf negativ prüfen (Exception rollt alles zurück)
        -- nur abziehen, wenn genug da ist (Bedingung im UPDATE → race-sicher, kein CHECK-Fehler)
        update bestaende set menge = menge - m_menge
            where artikelnummer=m_artnr and lagerplatz=m_nach and menge >= m_menge
            returning menge into v_cur;
        if not found then
            select menge into v_cur from bestaende where artikelnummer=m_artnr and lagerplatz=m_nach;
            raise exception 'Rückgängig nicht möglich — auf % sind nur % Stk', m_nach, coalesce(v_cur, 0);
        end if;
        insert into bestaende (artikelnummer, lagerplatz, menge) values (m_artnr, m_von, m_menge)
            on conflict (artikelnummer, lagerplatz) do update set menge = bestaende.menge + m_menge;
        delete from leermeldungen where artikelnummer=m_artnr and lagerplatz=m_von and gesehen=0;
        v_beschr := 'Umlagerung rückgängig: ' || m_menge || ' Stk ' || m_nach || ' → ' || m_von;

    elsif b.typ = 'Eingang' then
        update bestaende set menge = menge - b.menge
            where artikelnummer=b.artikelnummer and lagerplatz=b.lagerplatz and menge >= b.menge
            returning menge into v_neu;
        if not found then
            select menge into v_cur from bestaende where artikelnummer=b.artikelnummer and lagerplatz=b.lagerplatz;
            raise exception 'Rückgängig nicht möglich — auf % sind nur % Stk', b.lagerplatz, coalesce(v_cur, 0);
        end if;
        v_beschr := 'Einbuchung rückgängig: ' || b.menge || ' Stk ' || coalesce(b.artikelname,'') || ' auf ' || b.lagerplatz;

    elsif b.typ = 'Ausgang' then
        insert into bestaende (artikelnummer, lagerplatz, menge) values (b.artikelnummer, b.lagerplatz, b.menge)
            on conflict (artikelnummer, lagerplatz) do update set menge = bestaende.menge + b.menge
            returning menge into v_neu;
        if v_neu > 0 then
            delete from leermeldungen where artikelnummer=b.artikelnummer and lagerplatz=b.lagerplatz and gesehen=0;
        end if;
        v_beschr := 'Ausbuchung rückgängig: ' || b.menge || ' Stk ' || coalesce(b.artikelname,'') || ' auf ' || b.lagerplatz;

    else
        -- kann nach der Typ-Prüfung oben nicht eintreten; Absicherung für künftige Erweiterungen
        raise exception 'Unbekannter Rückgängig-Typ: %', b.typ;
    end if;

    update buchungen set rueckgaengig_gemacht = 1 where id = b.id;
    insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
        bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar, rueckgaengig_gemacht)
        values (now(), 'Rückgängig', b.artikelnummer, b.artikelname, b.gtin, b.lagerplatz, b.menge,
            null, null, null, null, v_beschr, 1);

    return v_beschr;
end;
$$;
revoke all on function rueckgaengig_eine(bigint) from anon, authenticated, public;


create or replace function rueckgaengig(p_buchung_id bigint)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_typ text; v_vorgang uuid; v_beschr text; v_teile integer := 1; v_naechste bigint;
begin
    select typ, vorgang into v_typ, v_vorgang from buchungen where id = p_buchung_id;
    -- mit dem neuesten offenen Teil des Vorgangs beginnen (sonst zählte ein
    -- jüngerer Teil als „neuere Buchung" und würde blockieren)
    if v_vorgang is not null then
        select coalesce(max(id), p_buchung_id) into p_buchung_id from buchungen
            where vorgang = v_vorgang and rueckgaengig_gemacht = 0 and id >= p_buchung_id;
    end if;
    v_beschr := rueckgaengig_eine(p_buchung_id);
    if v_vorgang is not null then
        loop
            -- jeweils den neuesten noch offenen Teil (die Prüfung „keine neuere
            -- Buchung" in rueckgaengig_eine bleibt so erfüllt)
            select max(id) into v_naechste from buchungen
                where vorgang = v_vorgang and rueckgaengig_gemacht = 0;
            exit when v_naechste is null;
            perform rueckgaengig_eine(v_naechste);
            v_teile := v_teile + 1;
        end loop;
    end if;
    if v_teile > 1 then
        v_beschr := v_beschr || ' (+ ' || (v_teile - 1) || ' weitere' || case when v_teile = 2 then 'r Teil' else ' Teile' end || ' desselben Vorgangs)';
    end if;
    return jsonb_build_object('ok', true, 'typ', v_typ, 'beschreibung', v_beschr, 'teile', v_teile);
end;
$$;
revoke all on function rueckgaengig(bigint) from anon, public;
grant execute on function rueckgaengig(bigint) to authenticated;


create or replace function lagerplatz_umbenennen(p_alt text, p_neu text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_umbenannt integer;
begin
    p_alt := trim(p_alt); p_neu := trim(p_neu);
    if p_alt = '' or p_neu = '' then raise exception 'Alter und neuer Name sind Pflicht'; end if;
    if p_alt = p_neu then raise exception 'Alter und neuer Name sind identisch'; end if;
    if not (exists (select 1 from bestaende where lagerplatz=p_alt) or exists (select 1 from lagerplaetze where name=p_alt)) then
        raise exception 'Lagerplatz „%" nicht gefunden', p_alt;
    end if;
    if exists (select 1 from bestaende where lagerplatz=p_neu) or exists (select 1 from lagerplaetze where name=p_neu) then
        raise exception 'Lagerplatz „%" existiert bereits. Zum Zusammenführen bitte „Zusammenlegen" verwenden.', p_neu;
    end if;
    update bestaende     set lagerplatz=p_neu where lagerplatz=p_alt;
    get diagnostics v_umbenannt = row_count;
    -- verwaiste offene Meldungen unter dem neuen Namen erledigen (sonst Konflikt mit uq_leer_offen)
    update leermeldungen set gesehen = 1 where gesehen = 0 and lagerplatz = p_neu
        and artikelnummer in (select artikelnummer from leermeldungen where gesehen = 0 and lagerplatz = p_alt);
    update leermeldungen set lagerplatz=p_neu where lagerplatz=p_alt;
    update lagerplaetze  set name=p_neu       where name=p_alt;
    insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge, kommentar)
        values (now(), 'Umbenennung', '—', '', '', p_alt||' → '||p_neu, v_umbenannt,
                'RENAME|'||json_build_object('alt',p_alt,'neu',p_neu)::text);
    return jsonb_build_object('ok', true, 'umbenannt', v_umbenannt);
end; $$;
revoke all on function lagerplatz_umbenennen(text,text) from anon, public;
grant execute on function lagerplatz_umbenennen(text,text) to authenticated;


create or replace function lagerplatz_zusammenlegen(p_quellen jsonb, p_ziel text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_quellen text[]; v_betroffen text[]; v_snap jsonb; v_sum jsonb; r record; q text;
        v_lp jsonb; v_ziel_neu boolean;
begin
    p_ziel := trim(p_ziel);
    select array(select distinct trim(x) from jsonb_array_elements_text(p_quellen) x where trim(x) <> '') into v_quellen;
    if array_length(v_quellen,1) is null or array_length(v_quellen,1) < 2 then raise exception 'Bitte mindestens zwei Lagerplätze auswählen'; end if;
    if p_ziel = '' then raise exception 'Ein Zielname ist Pflicht'; end if;
    foreach q in array v_quellen loop
        if not (exists (select 1 from bestaende where lagerplatz=q) or exists (select 1 from lagerplaetze where name=q)) then
            raise exception 'Lagerplatz „%" nicht gefunden', q;
        end if;
    end loop;
    v_betroffen := v_quellen;
    if not (p_ziel = any(v_betroffen)) and exists (select 1 from bestaende where lagerplatz=p_ziel) then
        v_betroffen := array_append(v_betroffen, p_ziel);
    end if;
    -- Snapshot für Rückgängig: Bestände + Platz-Einstellungen (Palette/Kanal) der
    -- Quellen, und ob das Ziel vorher schon existierte
    select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) into v_lp from lagerplaetze l where name = any(v_quellen);
    v_ziel_neu := not (exists (select 1 from bestaende where lagerplatz=p_ziel) or exists (select 1 from lagerplaetze where name=p_ziel));
    select coalesce(jsonb_object_agg(lp, arts), '{}'::jsonb) into v_snap
        from (select lagerplatz lp, jsonb_object_agg(artikelnummer, menge) arts
              from bestaende where lagerplatz = any(v_betroffen) group by lagerplatz) s;
    -- Summen je Artikel
    select coalesce(jsonb_object_agg(artikelnummer, m), '{}'::jsonb) into v_sum
        from (select artikelnummer, sum(menge) m from bestaende where lagerplatz = any(v_betroffen) group by artikelnummer) s;
    delete from bestaende where lagerplatz = any(v_betroffen);
    for r in select key as artnr, value::integer as m from jsonb_each_text(v_sum) loop
        insert into bestaende (artikelnummer, lagerplatz, menge) values (r.artnr, p_ziel, r.m)
            on conflict (artikelnummer, lagerplatz) do update set menge = excluded.menge;
    end loop;
    -- Offene Leermeldungen: Artikel, die am Ziel jetzt Bestand haben, sind erledigt;
    -- von den übrigen bleibt je Artikel nur eine (sonst Konflikt mit uq_leer_offen)
    update leermeldungen set gesehen = 1
        where gesehen = 0 and artikelnummer <> '—' and lagerplatz = any(array_append(v_quellen, p_ziel))
          and coalesce((v_sum->>artikelnummer)::integer, 0) > 0;
    update leermeldungen l set gesehen = 1
        where l.gesehen = 0 and l.artikelnummer <> '—' and l.lagerplatz = any(array_append(v_quellen, p_ziel))
          and exists (select 1 from leermeldungen k where k.gesehen = 0 and k.artikelnummer = l.artikelnummer
                      and k.lagerplatz = any(array_append(v_quellen, p_ziel)) and k.id < l.id);
    update leermeldungen set lagerplatz=p_ziel where lagerplatz = any(v_quellen) and lagerplatz <> p_ziel;
    delete from lagerplaetze where name = any(v_quellen) and name <> p_ziel;
    insert into lagerplaetze (name, angelegt, palette, kanal) values (p_ziel, now()::text, '', 0) on conflict (name) do nothing;
    insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge, kommentar)
        values (now(), 'Zusammenlegung', '—', '', '', array_to_string(v_quellen,' + ')||' → '||p_ziel,
                array_length(v_quellen,1), 'MERGE|'||jsonb_build_object('ziel',p_ziel,'snap',v_snap,'lp',v_lp,'ziel_neu',v_ziel_neu)::text);
    return jsonb_build_object('ok', true, 'ziel', p_ziel, 'zusammengelegt', array_length(v_quellen,1));
end; $$;
revoke all on function lagerplatz_zusammenlegen(jsonb,text) from anon, public;
grant execute on function lagerplatz_zusammenlegen(jsonb,text) to authenticated;


create or replace function lagerplatz_loeschen(p_name text, p_mit_bestand boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_snap jsonb; v_artikel integer; v_stueck integer; v_hat_bestand boolean; v_lp jsonb;
begin
    p_name := trim(p_name);
    if p_name = '' then raise exception 'Kein Lagerplatz angegeben'; end if;
    if not (exists (select 1 from bestaende where lagerplatz=p_name) or exists (select 1 from lagerplaetze where name=p_name)) then
        raise exception 'Lagerplatz „%" nicht gefunden', p_name;
    end if;
    select coalesce(bool_or(menge>0), false), count(*), coalesce(sum(menge),0)
        into v_hat_bestand, v_artikel, v_stueck from bestaende where lagerplatz=p_name;
    if v_hat_bestand and not coalesce(p_mit_bestand,false) then
        raise exception 'BESTAND_VORHANDEN: Auf „%" liegen noch % Artikel / % Stück. Löschen nur mit Bestätigung.', p_name, v_artikel, v_stueck;
    end if;
    select coalesce(jsonb_object_agg(artikelnummer, menge), '{}'::jsonb) into v_snap from bestaende where lagerplatz=p_name;
    -- Palette/Kanal/Anlegedatum für Rückgängig mitsichern
    select to_jsonb(l) into v_lp from lagerplaetze l where name = p_name;
    delete from bestaende where lagerplatz=p_name;
    delete from lagerplaetze where name=p_name;
    update leermeldungen set gesehen=1 where lagerplatz=p_name and gesehen=0;
    insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge, bestand_lp_vorher, kommentar)
        values (now(), 'Lagerplatz gelöscht', '—', '', '', p_name, v_artikel, v_stueck,
                'DELETE|'||jsonb_build_object('platz',p_name,'snap',v_snap,'lp',v_lp)::text);
    return jsonb_build_object('ok', true, 'name', p_name, 'artikel', v_artikel, 'stueck', v_stueck);
end; $$;
revoke all on function lagerplatz_loeschen(text,boolean) from anon, public;
grant execute on function lagerplatz_loeschen(text,boolean) to authenticated;


create or replace function bestand_csv_import(p_zeilen jsonb, p_modus text default 'teil', p_anlegen boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
    r record;
    v_artnr text; v_lp text; v_bestand integer; v_name text; v_gtin text; v_setflag integer;
    v_art_name text; v_art_gtin text;
    v_lp_vorher integer; v_gesamt_vorher integer; v_gesamt_nachher integer;
    v_existiert boolean;
    v_aktualisiert integer := 0;
    v_unveraendert integer := 0;
    v_ohne_lp integer := 0;
    v_neu_angelegt integer := 0;
    v_nicht_gefunden text[] := '{}';
    v_auf_null integer := 0;
    v_now timestamptz := now();
    v_had_bestand boolean;
    v_beispiele text;
    v_gtin_besitzer text;
    v_gtin_konflikte text[] := '{}';
    a record; b record;
begin
    if p_modus is null or p_modus not in ('teil','komplett') then
        raise exception 'Ungültiger Import-Modus „%" (erlaubt: teil, komplett)', p_modus;
    end if;
    if p_zeilen is null or jsonb_typeof(p_zeilen) <> 'array' then
        raise exception 'Import abgebrochen: keine Zeilen übergeben.';
    end if;

    drop table if exists pg_temp.tmp_csv_zeilen;
    drop table if exists pg_temp.tmp_csv_kombi;
    drop table if exists pg_temp.tmp_csv_artikel;
    create temp table pg_temp.tmp_csv_zeilen as
        select * from jsonb_to_recordset(p_zeilen)
            as x(artikelnummer text, lagerplatz text, bestand integer, artikelname text, gtin text, set_flag integer);

    -- ── Vorab-Prüfungen (nichts wurde bisher geschrieben) ──
    select string_agg(artikelnummer || ' (' || bestand || ')', ', ') into v_beispiele
        from (select trim(artikelnummer) as artikelnummer, bestand from pg_temp.tmp_csv_zeilen
              where bestand < 0 limit 5) t;
    if v_beispiele is not null then
        raise exception 'Import abgebrochen: Datei enthält negative Bestände, z. B. %', v_beispiele;
    end if;

    if p_modus = 'komplett' then
        select string_agg(artikelnummer, ', ') into v_beispiele
            from (select trim(artikelnummer) as artikelnummer from pg_temp.tmp_csv_zeilen
                  where coalesce(trim(artikelnummer),'') <> '' and bestand is not null
                    and coalesce(trim(lagerplatz),'') = '' limit 5) t;
        if v_beispiele is not null then
            raise exception 'Komplett-Import abgebrochen: Zeilen ohne Lagerplatz in der Datei (z. B. %). Nichts wurde geändert.', v_beispiele;
        end if;
        if not exists (select 1 from pg_temp.tmp_csv_zeilen
                       where coalesce(trim(artikelnummer),'') <> '' and bestand is not null
                         and coalesce(trim(lagerplatz),'') <> '') then
            raise exception 'Komplett-Import abgebrochen: Datei enthält keine gültige Zeile (Artikelnummer + Lagerplatz + Bestand). Nichts wurde geändert.';
        end if;
    end if;

    create temp table pg_temp.tmp_csv_kombi as
        select distinct trim(artikelnummer) as artikelnummer, trim(lagerplatz) as lagerplatz
        from pg_temp.tmp_csv_zeilen where lagerplatz is not null and trim(lagerplatz) <> '';
    create temp table pg_temp.tmp_csv_artikel as
        select distinct trim(artikelnummer) as artikelnummer
        from pg_temp.tmp_csv_zeilen where artikelnummer is not null and trim(artikelnummer) <> '';
    create index on pg_temp.tmp_csv_kombi (artikelnummer, lagerplatz);
    create index on pg_temp.tmp_csv_artikel (artikelnummer);

    for r in select * from pg_temp.tmp_csv_zeilen loop
        v_artnr := trim(r.artikelnummer);
        if v_artnr is null or v_artnr = '' or r.bestand is null then continue; end if;
        v_lp := nullif(trim(coalesce(r.lagerplatz,'')), '');
        v_name := nullif(trim(coalesce(r.artikelname,'')), '');
        v_gtin := coalesce(trim(r.gtin), '');
        v_setflag := r.set_flag;
        v_bestand := r.bestand;

        select artikelname, gtin into v_art_name, v_art_gtin from artikel where artikelnummer = v_artnr;
        if not found then
            if p_anlegen then
                -- GTIN schon bei einem anderen Artikel? Wird trotzdem übernommen (z.B. ein als
                -- defekt geführter Zweit-Artikel mit derselben Hersteller-EAN wie das Original
                -- ist ein legitimer Fall) - nur zur Information im Ergebnis gemeldet, nicht blockiert.
                if v_gtin <> '' then
                    select artikelnummer into v_gtin_besitzer from artikel where gtin = v_gtin limit 1;
                    if found then
                        v_gtin_konflikte := array_append(v_gtin_konflikte, v_artnr || ': ' || v_gtin || ' auch bei ' || v_gtin_besitzer);
                    end if;
                end if;
                insert into artikel (artikelnummer, artikelname, gtin, ist_set)
                    values (v_artnr, coalesce(v_name, v_artnr), v_gtin, coalesce(v_setflag,0));
                v_neu_angelegt := v_neu_angelegt + 1;
                v_art_name := coalesce(v_name, v_artnr); v_art_gtin := v_gtin;
            else
                v_nicht_gefunden := array_append(v_nicht_gefunden, v_artnr);
                continue;
            end if;
        else
            -- neue GTIN gehört schon einem anderen Artikel? Wird trotzdem übernommen (siehe
            -- Kommentar oben) - nur zur Information im Ergebnis gemeldet, nicht blockiert.
            if p_anlegen and v_gtin <> '' and v_gtin <> coalesce(v_art_gtin,'') then
                select artikelnummer into v_gtin_besitzer from artikel
                    where gtin = v_gtin and artikelnummer <> v_artnr limit 1;
                if found then
                    v_gtin_konflikte := array_append(v_gtin_konflikte, v_artnr || ': ' || v_gtin || ' auch bei ' || v_gtin_besitzer);
                end if;
            end if;
            if p_anlegen and (v_name is not null or v_gtin <> '') then
                update artikel set
                    artikelname = coalesce(v_name, artikelname),
                    gtin = case when v_gtin <> '' then v_gtin else gtin end
                    where artikelnummer = v_artnr
                    returning artikelname, gtin into v_art_name, v_art_gtin;
            end if;
        end if;
        if v_setflag is not null then
            update artikel set ist_set = v_setflag where artikelnummer = v_artnr;
        end if;

        if v_lp is null then
            v_ohne_lp := v_ohne_lp + 1;
            continue;
        end if;

        select menge into v_lp_vorher from bestaende where artikelnummer = v_artnr and lagerplatz = v_lp;
        v_existiert := found;
        v_lp_vorher := coalesce(v_lp_vorher, 0);

        -- unverändert → nichts schreiben, nichts protokollieren
        if v_existiert and v_lp_vorher = v_bestand then
            v_unveraendert := v_unveraendert + 1;
            continue;
        end if;

        select coalesce(sum(menge),0) into v_gesamt_vorher from bestaende where artikelnummer = v_artnr;

        insert into bestaende (artikelnummer, lagerplatz, menge) values (v_artnr, v_lp, v_bestand)
            on conflict (artikelnummer, lagerplatz) do update set menge = v_bestand;

        v_gesamt_nachher := v_gesamt_vorher - v_lp_vorher + v_bestand;

        insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar)
            values (v_now, 'CSV-Import', v_artnr, v_art_name, v_art_gtin, v_lp,
                abs(v_bestand - v_lp_vorher), v_lp_vorher, v_bestand, v_gesamt_vorher, v_gesamt_nachher, 'CSV-Import');

        if v_lp_vorher > 0 and v_bestand = 0 then
            if not exists (select 1 from leermeldungen where artikelnummer=v_artnr and lagerplatz=v_lp and gesehen=0) then
                insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
                    values (v_now, v_artnr, v_art_name, v_art_gtin, v_lp, 0, '') on conflict do nothing;
            end if;
        elsif v_bestand > 0 then
            delete from leermeldungen where artikelnummer=v_artnr and lagerplatz=v_lp and gesehen=0;
        end if;

        v_aktualisiert := v_aktualisiert + 1;
    end loop;

    -- Komplett-Import: alle Platz-Kombis, die NICHT in der Datei stehen, auf 0.
    -- Ausnahme: unbekannte Artikel (Platzhalter WE-0-…) - die kennt JTL nicht,
    -- sie können also nie in einer JTL-Datei stehen und würden sonst bei jedem
    -- Komplett-Import still auf 0 gesetzt.
    if p_modus = 'komplett' then
        for a in select artikelnummer from artikel where unbekannt = 0 loop
            select exists(select 1 from bestaende where artikelnummer = a.artikelnummer and menge > 0) into v_had_bestand;
            for b in select lagerplatz, menge from bestaende where artikelnummer = a.artikelnummer and menge <> 0 loop
                if exists (select 1 from pg_temp.tmp_csv_kombi k where k.artikelnummer = a.artikelnummer and k.lagerplatz = b.lagerplatz) then
                    continue;
                end if;
                select coalesce(sum(menge),0) into v_gesamt_vorher from bestaende where artikelnummer = a.artikelnummer;
                update bestaende set menge = 0 where artikelnummer = a.artikelnummer and lagerplatz = b.lagerplatz;
                select artikelname, gtin into v_art_name, v_art_gtin from artikel where artikelnummer = a.artikelnummer;
                insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
                    bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar)
                    values (v_now, 'CSV-Import', a.artikelnummer, v_art_name, v_art_gtin, b.lagerplatz,
                        b.menge, b.menge, 0, v_gesamt_vorher, v_gesamt_vorher - b.menge, 'CSV-Import (Komplett — auf 0 gesetzt)');
                if not exists (select 1 from leermeldungen where artikelnummer=a.artikelnummer and lagerplatz=b.lagerplatz and gesehen=0) then
                    insert into leermeldungen (zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
                        values (v_now, a.artikelnummer, v_art_name, v_art_gtin, b.lagerplatz, 0, '') on conflict do nothing;
                end if;
            end loop;
            if not exists (select 1 from pg_temp.tmp_csv_artikel t where t.artikelnummer = a.artikelnummer) and v_had_bestand then
                v_auf_null := v_auf_null + 1;
            end if;
        end loop;
    end if;

    drop table if exists pg_temp.tmp_csv_zeilen;
    drop table if exists pg_temp.tmp_csv_kombi;
    drop table if exists pg_temp.tmp_csv_artikel;

    return jsonb_build_object('ok', true, 'aktualisiert', v_aktualisiert, 'unveraendert', v_unveraendert,
        'ohne_lagerplatz', v_ohne_lp, 'neu_angelegt', v_neu_angelegt,
        'auf_null_gesetzt', v_auf_null, 'nicht_gefunden', coalesce(array_length(v_nicht_gefunden,1),0),
        'beispiele_nicht_gefunden', to_jsonb(v_nicht_gefunden[1:5]),
        'gtin_konflikte', coalesce(array_length(v_gtin_konflikte,1),0),
        'beispiele_gtin_konflikte', to_jsonb(v_gtin_konflikte[1:5]));
end; $$;
revoke all on function bestand_csv_import(jsonb,text,boolean) from anon, public;
grant execute on function bestand_csv_import(jsonb,text,boolean) to authenticated;


create or replace function backup_wiederherstellen(p_daten jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
-- Robust gegen Unstimmigkeiten IN der Sicherungsdatei (Stand 27.09.2026):
-- Das Backup liest die Tabellen nacheinander. Wird genau in diesen Sekunden
-- gebucht/angelegt/gelöscht, kann die Datei (a) einen Bestand zu einem Artikel
-- enthalten, der in der Artikelliste fehlt, oder (b) eine Zeile doppelt
-- enthalten (Seitenwechsel beim Auslesen). Früher brach das Einspielen daran
-- komplett ab - ausgerechnet im Notfall. Jetzt werden solche Einzelzeilen
-- übersprungen und im Ergebnis gemeldet ('uebersprungen', 'beispiele_ohne_artikel').
declare
    v_artikel integer; v_bestaende integer; v_lagerplaetze integer;
    v_buchungen integer; v_leermeldungen integer; v_paletten integer;
    v_negativ integer; v_ohne_artikel integer; v_beispiele jsonb;
    v_ueber jsonb := '{}'::jsonb;
    v_n integer;
begin
    if p_daten is null or not (p_daten ? 'artikel') or not (p_daten ? 'bestaende') then
        raise exception 'Ungültige Sicherungsdatei: erwartete Felder (artikel, bestaende, …) fehlen.';
    end if;

    -- "where true": Supabase (pg-safeupdate) blockiert DELETE ohne WHERE-Klausel.
    delete from bestaende where true;
    delete from artikel where true;
    delete from lagerplaetze where true;
    delete from buchungen where true;
    delete from leermeldungen where true;

    -- unbekannt: ältere Sicherungen haben die Spalte nicht → 0
    insert into artikel (artikelnummer, artikelname, gtin, ist_set, online, unbekannt)
        select artikelnummer, coalesce(artikelname,''), coalesce(gtin,''),
               case when ist_set = 1 then 1 else 0 end,
               case when online in (1,2) then online else 0 end,
               case when unbekannt = 1 then 1 else 0 end
        from jsonb_to_recordset(coalesce(p_daten->'artikel', '[]'::jsonb)) as x(
            artikelnummer text, artikelname text, gtin text, ist_set smallint, online smallint, unbekannt smallint)
        where artikelnummer is not null
        on conflict (artikelnummer) do nothing;
    get diagnostics v_artikel = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'artikel', '[]'::jsonb)) - v_artikel;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('artikel', v_n); end if;

    -- Ältere Sicherungen (vor Paket 2) können negative Bestände enthalten, die der
    -- CHECK (menge >= 0) nicht mehr zulässt. Statt die Wiederherstellung scheitern
    -- zu lassen: auf 0 setzen und im Ergebnis melden ('negativ_auf_null').
    select count(*) into v_negativ
        from jsonb_to_recordset(coalesce(p_daten->'bestaende', '[]'::jsonb)) as x(menge integer)
        where menge < 0;
    -- Bestände zu Artikeln, die nicht in der Datei stehen, würde der Fremdschlüssel
    -- ablehnen (und damit das ganze Einspielen) → überspringen und melden.
    select count(*), jsonb_agg(b) filter (where rn <= 5)
        into v_ohne_artikel, v_beispiele
        from (select x.artikelnummer || ' @ ' || coalesce(x.lagerplatz,'?') || ' (' || coalesce(x.menge,0) || ')' as b,
                     row_number() over () as rn
              from jsonb_to_recordset(coalesce(p_daten->'bestaende', '[]'::jsonb)) as x(
                  artikelnummer text, lagerplatz text, menge integer)
              where x.artikelnummer is not null
                and not exists (select 1 from artikel a where a.artikelnummer = x.artikelnummer)) t;
    insert into bestaende (artikelnummer, lagerplatz, menge)
        select artikelnummer, lagerplatz, greatest(coalesce(menge,0), 0)
        from jsonb_to_recordset(coalesce(p_daten->'bestaende', '[]'::jsonb)) as x(
            artikelnummer text, lagerplatz text, menge integer)
        where artikelnummer is not null and lagerplatz is not null
          and exists (select 1 from artikel a where a.artikelnummer = x.artikelnummer)
        on conflict (artikelnummer, lagerplatz) do nothing;
    get diagnostics v_bestaende = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'bestaende', '[]'::jsonb)) - v_bestaende - v_ohne_artikel;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('bestaende', v_n); end if;

    insert into lagerplaetze (name, angelegt, palette, kanal)
        select name, coalesce(angelegt,''), coalesce(palette,''), case when kanal in (1,2) then kanal else 0 end
        from jsonb_to_recordset(coalesce(p_daten->'lagerplaetze', '[]'::jsonb)) as x(
            name text, angelegt text, palette text, kanal smallint)
        where name is not null
        on conflict (name) do nothing;
    get diagnostics v_lagerplaetze = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'lagerplaetze', '[]'::jsonb)) - v_lagerplaetze;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('lagerplaetze', v_n); end if;

    insert into buchungen (id, zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
        bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher,
        kommentar, rueckgaengig_gemacht, vorgang)
        select id, zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher,
            kommentar, case when rueckgaengig_gemacht = 1 then 1 else 0 end, vorgang
        from jsonb_to_recordset(coalesce(p_daten->'buchungen', '[]'::jsonb)) as x(
            id bigint, zeitstempel timestamptz, typ text, artikelnummer text, artikelname text, gtin text,
            lagerplatz text, menge integer, bestand_lp_vorher integer, bestand_lp_nachher integer,
            bestand_gesamt_vorher integer, bestand_gesamt_nachher integer, kommentar text,
            rueckgaengig_gemacht smallint, vorgang uuid)
        where id is not null
        on conflict (id) do nothing;
    get diagnostics v_buchungen = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'buchungen', '[]'::jsonb)) - v_buchungen;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('buchungen', v_n); end if;
    -- Identity-Sequenz nachziehen, sonst kollidiert der nächste normale INSERT
    -- (id wurde oben explizit mitgeliefert, "generated by default" erlaubt das).
    perform setval(pg_get_serial_sequence('buchungen','id'), coalesce((select max(id) from buchungen), 0) + 1, false);

    insert into leermeldungen (id, zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, gesehen, hinweis)
        select id, zeitstempel, artikelnummer, artikelname, gtin, lagerplatz, case when gesehen = 1 then 1 else 0 end, coalesce(hinweis,'')
        from jsonb_to_recordset(coalesce(p_daten->'leermeldungen', '[]'::jsonb)) as x(
            id bigint, zeitstempel timestamptz, artikelnummer text, artikelname text, gtin text,
            lagerplatz text, gesehen smallint, hinweis text)
        where id is not null
        on conflict do nothing;   -- doppelte id ODER doppelte offene Meldung (uq_leer_offen)
    get diagnostics v_leermeldungen = row_count;
    v_n := jsonb_array_length(coalesce(p_daten->'leermeldungen', '[]'::jsonb)) - v_leermeldungen;
    if v_n > 0 then v_ueber := v_ueber || jsonb_build_object('leermeldungen', v_n); end if;
    perform setval(pg_get_serial_sequence('leermeldungen','id'), coalesce((select max(id) from leermeldungen), 0) + 1, false);

    -- "paletten" gibt es erst seit später hinzugekommenen Backups. Nur anfassen,
    -- wenn der Schlüssel im JSON vorhanden ist - so lassen ältere Sicherungen
    -- (ohne diesen Schlüssel) die aktuell gepflegten Palettennamen unangetastet,
    -- statt sie versehentlich auf leer zurückzusetzen. Das Anlegedatum ("erstellt")
    -- wird mit übernommen (fehlt es in der Datei: jetzt).
    if p_daten ? 'paletten' then
        delete from paletten where true;
        insert into paletten (name, erstellt)
            select name, coalesce(erstellt, now())
            from jsonb_to_recordset(coalesce(p_daten->'paletten', '[]'::jsonb)) as x(name text, erstellt timestamptz)
            where name is not null and trim(name) <> ''
            on conflict (name) do nothing;
        get diagnostics v_paletten = row_count;
    end if;

    return jsonb_build_object('ok', true, 'artikel', v_artikel, 'bestaende', v_bestaende,
        'lagerplaetze', v_lagerplaetze, 'buchungen', v_buchungen, 'leermeldungen', v_leermeldungen,
        'paletten', v_paletten, 'negativ_auf_null', v_negativ,
        'bestaende_ohne_artikel', v_ohne_artikel, 'beispiele_ohne_artikel', coalesce(v_beispiele, '[]'::jsonb),
        'uebersprungen', v_ueber);
end; $$;
revoke all on function backup_wiederherstellen(jsonb) from anon, public;
grant execute on function backup_wiederherstellen(jsonb) to authenticated;


create or replace function unbekannt_karton_naechster()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_akt text; v_nr integer; v_neu text;
begin
    perform pg_advisory_xact_lock(hashtext('lagerpal_unbekannt'));
    v_akt := unbekannt_karton_aktuell();
    -- Doppelklick-Schutz: aus einem leeren Karton wird kein weiterer gemacht
    if v_akt is not null and not exists (select 1 from bestaende where lagerplatz = v_akt and menge > 0) then
        raise exception 'Karton % ist noch leer - kein neuer Karton nötig', v_akt;
    end if;
    v_nr := coalesce(substring(v_akt from '([0-9]+)$')::integer, 0) + 1;
    v_neu := 'Unbekannt-' || lpad(v_nr::text, greatest(2, length(v_nr::text)), '0');   -- ab 100 nicht abschneiden
    insert into lagerplaetze (name, angelegt, palette, kanal) values (v_neu, now()::text, '', 0)
        on conflict (name) do nothing;
    return jsonb_build_object('ok', true, 'alt', v_akt, 'neu', v_neu);
end; $$;
revoke all on function unbekannt_karton_naechster() from anon, public;
grant execute on function unbekannt_karton_naechster() to authenticated;


commit;

-- Kontrolle (sollte 2 Zeilen liefern: karton_neu, rueckgaengig_eine)
select proname from pg_proc where proname in ('karton_neu','rueckgaengig_eine') order by 1;
