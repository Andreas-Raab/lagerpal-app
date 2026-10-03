-- ═══════════════════════════════════════════════════════════════════════
-- LagerPal – UPDATE Paket 3a (Stand 10/2026)
-- ═══════════════════════════════════════════════════════════════════════
-- Für ein BESTEHENDES System im Stand Paket 2 (Daten bleiben erhalten). Im
-- Supabase SQL-Editor komplett einfügen und ausführen. Kann gefahrlos mehrfach
-- ausgeführt werden. ZUERST im Testsystem, dann im echten System - und zwar
-- BEVOR die neue index.html live geht (die alte App läuft damit unverändert weiter).
--
-- Ganz unten wird der Fingerabdruck angezeigt. Er muss dem Wert in der
-- Testanleitung entsprechen.
--
-- Inhalt:
--  • Bestandsimport: EAN, die sich nur durch fehlende führende Nullen
--    unterscheidet, überschreibt die vorhandene nicht mehr; Stammdaten-
--    Änderungen und neu angelegte Artikel werden protokolliert
--  • Inventur: prüft, ob seit dem Laden auf dem Platz gebucht wurde
--  • Amazon-Status: „nicht ändern" für unbekannte Werte; nur echte Änderungen zählen
--  • Protokoll: Gesamtbestand auch bei Palette sortieren und Sammel-Ausbuchen
--  • Übersicht: Inventur-Zugang beim Einräumen zählt nicht mehr als „Heute ein"
-- ═══════════════════════════════════════════════════════════════════════

begin;

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
    v_gesamt integer;
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
    select coalesce(sum(menge), 0) into v_gesamt from bestaende where artikelnummer = p_artikelnummer;

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
                v_von_vorher, v_von_nachher, v_gesamt, v_gesamt,
                'MOVE|' || json_build_object('artnr', p_artikelnummer, 'von', p_quelle, 'nach', p_ziel, 'menge', v_verf)::text, v_vorgang);
    end if;

    if v_surplus > 0 then
        insert into bestaende (artikelnummer, lagerplatz, menge) values (p_artikelnummer, p_ziel, v_surplus)
            on conflict (artikelnummer, lagerplatz) do update set menge = bestaende.menge + v_surplus
            returning menge into v_ziel_nachher;
        insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar, vorgang)
            values (now(), 'Eingang', p_artikelnummer, v_name, v_gtin, p_ziel, v_surplus,
                v_ziel_nachher - v_surplus, v_ziel_nachher, v_gesamt, v_gesamt + v_surplus, 'Inventur-Zugang (Einräumen)', v_vorgang);
        -- für den Reiter „Abgleich": mehr gefunden, als auf der Quelle gebucht war
        insert into mengen_abweichungen (art, artikelnummer, menge, offen, quelle, karton, vorgang)
            values ('mehr', p_artikelnummer, v_surplus, v_surplus, p_quelle, p_ziel, v_vorgang);
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


create or replace function sammel_ausbuchen(p_artikelnummern text[])
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
    r record; v_name text; v_gtin text; v_gesamt integer;
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
        select coalesce(sum(menge), 0) into v_gesamt from bestaende where artikelnummer = r.artikelnummer;
        update bestaende set menge = 0 where artikelnummer = r.artikelnummer and lagerplatz = r.lagerplatz;
        insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge,
            bestand_lp_vorher, bestand_lp_nachher, bestand_gesamt_vorher, bestand_gesamt_nachher, kommentar, vorgang)
            values (now(), 'Ausgang', r.artikelnummer, v_name, v_gtin, r.lagerplatz, r.menge,
                    r.menge, 0, v_gesamt, v_gesamt - r.menge, 'Sammel-Ausbuchen (Suche)', v_vorgang);
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
    v_soll integer; v_konflikte jsonb := '[]'::jsonb;
begin
    if p_lagerplatz is null or trim(p_lagerplatz) = '' then raise exception 'Kein Lagerplatz angegeben'; end if;
    -- Werte: entweder die gezählte Menge (alte App) oder {ist, soll}. Mit „soll"
    -- wird geprüft, ob seit dem Laden der Liste auf dem Platz gebucht wurde - dann
    -- wird NICHTS übernommen und die abweichenden Zeilen gehen an die App zurück.
    perform 1 from bestaende where lagerplatz = p_lagerplatz for update;
    for r in select key as artnr, value as wert from jsonb_each(p_zaehlungen) loop
        if jsonb_typeof(r.wert) = 'object' and r.wert ? 'soll' then
            v_soll := (r.wert->>'soll')::integer;
            select coalesce((select menge from bestaende
                             where artikelnummer = trim(r.artnr) and lagerplatz = p_lagerplatz), 0) into v_vorher;
            if v_vorher <> v_soll then
                v_konflikte := v_konflikte || jsonb_build_object('artikelnummer', trim(r.artnr), 'soll', v_soll, 'aktuell', v_vorher);
            end if;
        end if;
    end loop;
    if jsonb_array_length(v_konflikte) > 0 then
        return jsonb_build_object('ok', false, 'lagerplatz', p_lagerplatz, 'anzahl_geaendert', 0, 'konflikte', v_konflikte);
    end if;
    for r in select key as artnr, value as wert from jsonb_each(p_zaehlungen) loop
        v_artnr := trim(r.artnr);
        begin
            v_ist := case when jsonb_typeof(r.wert) = 'object' then r.wert->>'ist' else r.wert #>> '{}' end::integer;
        exception when others then continue; end;
        if v_ist is null then continue; end if;
        if v_artnr = '' or v_ist < 0 then continue; end if;
        select artikelname, gtin into v_name, v_gtin from artikel where artikelnummer = v_artnr;
        if not found then continue; end if;
        select menge into v_vorher from bestaende where artikelnummer = v_artnr and lagerplatz = p_lagerplatz;
        if not found then v_vorher := 0; end if;
        -- nochmals prüfen: eine Zeile, die es bei der Prüfung oben noch nicht gab
        -- (Einbuchen auf leeren Platz), ist von der Sperre nicht erfasst
        if jsonb_typeof(r.wert) = 'object' and r.wert ? 'soll' and v_vorher <> (r.wert->>'soll')::integer then
            raise exception 'Während der Inventur wurde auf % gebucht. Bitte den Platz neu laden und erneut zählen.', p_lagerplatz;
        end if;
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


create or replace function amazon_status_setzen(p_mapping jsonb, p_modus text default 'nur')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_geaendert integer := 0;
    v_online integer; v_offline integer; v_unbekannt integer;
begin
    if p_modus is null or p_modus not in ('nur','voll') then
        raise exception 'Ungültiger Modus „%" (erlaubt: nur, voll)', p_modus;
    end if;
    -- Ziel je Artikel: Wert aus der Datei (online = null heißt „nicht ändern", z. B. bei
    -- einem unbekannten Status), sonst beim Vollabgleich „nicht online". Geschrieben
    -- und gezählt werden nur echte Änderungen.
    update artikel a
        set online = z.ziel
        from (select a2.artikelnummer,
                     case when x.artikelnummer is not null
                               then coalesce(case when x.online in (1,2) then x.online end, a2.online)
                          when p_modus = 'voll' then 2
                          else a2.online end as ziel
              from artikel a2
              left join (select distinct on (artikelnummer) artikelnummer, online
                         from jsonb_to_recordset(p_mapping) as m(artikelnummer text, online integer)
                         order by artikelnummer) x
                on x.artikelnummer = a2.artikelnummer) z
        where a.artikelnummer = z.artikelnummer and a.online is distinct from z.ziel;
    get diagnostics v_geaendert = row_count;
    select count(*) into v_online    from artikel where online = 1;
    select count(*) into v_offline   from artikel where online = 2;
    select count(*) into v_unbekannt from artikel where online = 0;
    insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge, kommentar)
        values (now(), 'CSV-Import', '—', '', '', null, jsonb_array_length(p_mapping),
                'Amazon-Status-Import (' || p_modus || '): ' || v_geaendert || ' geändert');
    return jsonb_build_object('ok', true, 'geaendert', v_geaendert,
        'online_gesamt', v_online, 'offline_gesamt', v_offline, 'unbekannt_gesamt', v_unbekannt);
end; $$;
revoke all on function amazon_status_setzen(jsonb,text) from anon, public;
grant execute on function amazon_status_setzen(jsonb,text) to authenticated;


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
    v_alt_name text; v_alt_gtin text; v_alt_set integer; v_aend text;
    v_stamm integer := 0;
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

        select artikelname, gtin, ist_set into v_art_name, v_art_gtin, v_alt_set from artikel where artikelnummer = v_artnr;
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
                insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge, kommentar)
                    values (v_now, 'Artikel angelegt', v_artnr, v_art_name, v_art_gtin, '—', null, 'Neu angelegt beim CSV-Import');
            else
                v_nicht_gefunden := array_append(v_nicht_gefunden, v_artnr);
                continue;
            end if;
        else
            v_alt_name := v_art_name; v_alt_gtin := v_art_gtin;
            -- Excel lässt führende Nullen weg („0012345678905" → „12345678905"):
            -- unterscheidet sich die EAN nur darin, bleibt die vorhandene stehen
            if v_gtin <> '' and ltrim(v_gtin, '0') = ltrim(coalesce(v_art_gtin, ''), '0') then
                v_gtin := coalesce(v_art_gtin, '');
            end if;
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
            if v_setflag is not null and v_setflag is distinct from coalesce(v_alt_set, 0) then
                update artikel set ist_set = v_setflag where artikelnummer = v_artnr;
            end if;
            -- Stammdaten-Änderungen nachvollziehbar protokollieren (früher still)
            v_aend := concat_ws(' · ',
                case when v_art_name is distinct from v_alt_name
                     then 'Name: „' || coalesce(v_alt_name, '') || '" → „' || coalesce(v_art_name, '') || '"' end,
                case when coalesce(v_art_gtin, '') <> coalesce(v_alt_gtin, '')
                     then 'EAN: ' || coalesce(nullif(v_alt_gtin, ''), '—') || ' → ' || coalesce(nullif(v_art_gtin, ''), '—') end,
                case when v_setflag is not null and v_setflag is distinct from coalesce(v_alt_set, 0)
                     then 'Set: ' || case when v_alt_set = 1 then 'ja' else 'nein' end || ' → ' || case when v_setflag = 1 then 'ja' else 'nein' end end);
            if v_aend <> '' then
                insert into buchungen (zeitstempel, typ, artikelnummer, artikelname, gtin, lagerplatz, menge, kommentar)
                    values (v_now, 'Artikeländerung (Import)', v_artnr, v_art_name, v_art_gtin, '—', null, v_aend);
                v_stamm := v_stamm + 1;
            end if;
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
        'ohne_lagerplatz', v_ohne_lp, 'neu_angelegt', v_neu_angelegt, 'stammdaten_geaendert', v_stamm,
        'auf_null_gesetzt', v_auf_null, 'nicht_gefunden', coalesce(array_length(v_nicht_gefunden,1),0),
        'beispiele_nicht_gefunden', to_jsonb(v_nicht_gefunden[1:5]),
        'gtin_konflikte', coalesce(array_length(v_gtin_konflikte,1),0),
        'beispiele_gtin_konflikte', to_jsonb(v_gtin_konflikte[1:5]));
end; $$;
revoke all on function bestand_csv_import(jsonb,text,boolean) from anon, public;
grant execute on function bestand_csv_import(jsonb,text,boolean) to authenticated;


create or replace view v_dashboard
with (security_invoker = true) as
with grenzen as (
  select date_trunc('day',  now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin' as tag_beginn,
         date_trunc('week', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin' as woche_beginn
)
select
  (select count(*) from artikel)                                             as artikel_gesamt,
  (select coalesce(sum(menge),0) from bestaende)                             as bestand_gesamt,
  (select count(distinct lagerplatz) from bestaende where menge>0)           as lp_mit_bestand,
  (select count(*) from (select lagerplatz from bestaende where menge>0
                         union select name from lagerplaetze) t)             as lp_gesamt,
  (select count(*) from artikel where ist_set=1)                             as set_artikel,
  (select count(*) from artikel a where not exists
     (select 1 from bestaende b where b.artikelnummer=a.artikelnummer and b.menge>0)) as artikel_ohne_bestand,
  (select count(*) from leermeldungen where gesehen=0)                       as leermeldungen_offen,
  (select count(*) from (select gtin from artikel where gtin<>''
                         group by gtin having count(*)>1) g)                 as gtin_mehrdeutig,
  (select count(*) from artikel where online=2)                             as nicht_online,
  (select count(*) from artikel where online=0)                             as online_unbekannt,
  (select coalesce(sum(menge),0) from buchungen
     where typ='Eingang' and rueckgaengig_gemacht=0 and kommentar is distinct from 'Inventur-Zugang (Einräumen)'
       and zeitstempel >= (select tag_beginn from grenzen)) as ein_heute,
  (select coalesce(sum(menge),0) from buchungen
     where typ='Ausgang' and rueckgaengig_gemacht=0 and zeitstempel >= (select tag_beginn from grenzen)) as aus_heute,
  (select coalesce(sum(menge),0) from buchungen
     where typ='Eingang' and rueckgaengig_gemacht=0 and kommentar is distinct from 'Inventur-Zugang (Einräumen)'
       and zeitstempel >= (select woche_beginn from grenzen)) as ein_woche,
  (select coalesce(sum(menge),0) from buchungen
     where typ='Ausgang' and rueckgaengig_gemacht=0 and zeitstempel >= (select woche_beginn from grenzen)) as aus_woche;

revoke all on v_dashboard from anon;
grant select on v_dashboard to authenticated;

commit;

-- Kontrolle: Fingerabdruck (muss dem Wert in der Testanleitung entsprechen)
select
  (select md5(string_agg(x, '|' order by x)) from (
     select 'f:'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||'):'||md5(pg_get_functiondef(p.oid)) x
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind = 'f'
     union all
     select 't:'||table_name||'.'||column_name||':'||data_type
       from information_schema.columns where table_schema = 'public'
     union all
     select 'p:'||tablename||'.'||policyname from pg_policies where schemaname = 'public'
  ) s) as fingerabdruck;
