-- Avisa tu Cita: base de datos para Supabase.
-- Pegar completo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
--
-- Qué se guarda: nombre, fecha, hora y estado de cada cita. Nada médico.
--
-- Quién puede hacer qué:
--   * Pacientes (sin cuenta): solo pueden buscar su cita con nombre y apellido
--     y avisar "en camino" / "no va". No pueden ver la lista de pacientes.
--   * Personal (doctor y asistente): entran con correo y contraseña y ven/editan todo,
--     pero solo si su correo está en la tabla "personal" (al final de este archivo).

create table if not exists public.citas (
  id         uuid primary key default gen_random_uuid(),
  fecha      date not null,
  hora       time not null,
  nombre     text not null,
  estado     text not null default 'pendiente' check (estado in ('pendiente', 'camino', 'no_va', 'llego')),
  aviso_en   timestamptz,
  creado_en  timestamptz not null default now()
);
create index if not exists citas_fecha on public.citas (fecha);

-- Versión anterior pedía los 4 números del seguro: ya no se usan
drop function if exists public.buscar_cita(text, text);
drop function if exists public.avisar_cita(uuid, text, text);
alter table public.citas drop column if exists nss4;
create unique index if not exists citas_fecha_hora on public.citas (fecha, hora);

create table if not exists public.personal (
  email text primary key
);

alter table public.citas enable row level security;
alter table public.personal enable row level security;

-- Pacientes (anon) nunca leen las tablas directo; el personal sí, filtrado por las reglas de abajo
revoke all on public.citas from anon;
revoke all on public.personal from anon, authenticated;
grant select, insert, update, delete on public.citas to authenticated;

-- ¿La persona que entró es del consultorio?
create or replace function public.es_personal()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.personal where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

drop policy if exists "personal ve y edita citas" on public.citas;
create policy "personal ve y edita citas" on public.citas
  for all to authenticated
  using (public.es_personal())
  with check (public.es_personal());

-- Quita acentos y mayúsculas para comparar nombres
create or replace function public.norm_txt(t text)
returns text
language sql immutable
as $$
  select translate(lower(trim(coalesce(t, ''))), 'áéíóúüñ', 'aeiouun');
$$;

-- Paciente: buscar su cita (de hoy en adelante). Pide al menos nombre y apellido.
create or replace function public.buscar_cita(p_nombre text)
returns table (id uuid, fecha date, hora time, nombre text, estado text)
language plpgsql stable security definer set search_path = public
as $$
declare
  palabras text[];
  hoy date := (now() at time zone 'America/Mexico_City')::date;
begin
  palabras := array(
    select w from regexp_split_to_table(public.norm_txt(p_nombre), '\s+') as w where length(w) >= 2
  );
  if coalesce(array_length(palabras, 1), 0) < 2 then return; end if;

  return query
    select c.id, c.fecha, c.hora, c.nombre, c.estado
    from public.citas c
    where c.fecha >= hoy
      and not exists (
        select 1 from unnest(palabras) as q
        where not exists (
          select 1 from regexp_split_to_table(public.norm_txt(c.nombre), '\s+') as n
          where n like q || '%'
        )
      )
    order by c.fecha, c.hora
    limit 3;
end;
$$;

-- Paciente: avisar "camino" o "no_va" sobre la cita que encontró
create or replace function public.avisar_cita(p_id uuid, p_estado text)
returns text
language plpgsql volatile security definer set search_path = public
as $$
declare
  nuevo text;
begin
  if p_estado not in ('camino', 'no_va') then return null; end if;
  update public.citas
     set estado = p_estado, aviso_en = now()
   where id = p_id
     and estado <> 'llego'
     and fecha >= (now() at time zone 'America/Mexico_City')::date
  returning estado into nuevo;
  return nuevo;
end;
$$;

revoke all on function public.buscar_cita(text) from public;
revoke all on function public.avisar_cita(uuid, text) from public;
grant execute on function public.buscar_cita(text) to anon, authenticated;
grant execute on function public.avisar_cita(uuid, text) to anon, authenticated;

-- Avisos en vivo para el panel del consultorio
do $$
begin
  alter publication supabase_realtime add table public.citas;
exception when duplicate_object then null;
end $$;

-- Borra solas las citas de hace más de 30 días (se corre al guardar una agenda nueva)
create or replace function public.limpiar_citas_viejas()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.citas where fecha < (now() at time zone 'America/Mexico_City')::date - 30;
  return null;
end;
$$;
drop trigger if exists limpiar_viejas on public.citas;
create trigger limpiar_viejas after insert on public.citas
  for each statement execute function public.limpiar_citas_viejas();

-- ============================================================
-- PANEL DEL CONSULTORIO: se entra con una sola contraseña.
-- La contraseña se guarda cifrada y nunca aparece en la página.
-- Para ponerla o cambiarla, corre aparte (no la guardes en este archivo):
--   insert into public.ajustes (id, clave_hash)
--   values (1, extensions.crypt('LA-CONTRASEÑA', extensions.gen_salt('bf')))
--   on conflict (id) do update set clave_hash = excluded.clave_hash;
-- ============================================================
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.ajustes (
  id         int primary key default 1 check (id = 1),
  clave_hash text not null
);
create table if not exists public.intentos (
  en timestamptz not null default now()
);
alter table public.ajustes enable row level security;
alter table public.intentos enable row level security;
revoke all on public.ajustes from anon, authenticated;
revoke all on public.intentos from anon, authenticated;

-- ¿La contraseña es correcta? Tras 20 errores en 15 minutos se bloquea un rato.
create or replace function public.clave_ok(p_clave text)
returns boolean
language plpgsql volatile security definer set search_path = public, extensions
as $$
declare
  h text;
  fallos int;
begin
  select count(*) into fallos from public.intentos where en > now() - interval '15 minutes';
  if fallos >= 20 then raise exception 'Demasiados intentos. Espere 15 minutos.'; end if;
  select clave_hash into h from public.ajustes where id = 1;
  if h is not null and h = crypt(coalesce(p_clave, ''), h) then return true; end if;
  insert into public.intentos default values;
  delete from public.intentos where en < now() - interval '1 day';
  return false;
end;
$$;
revoke all on function public.clave_ok(text) from public, anon, authenticated;

create or replace function public.entrar_consultorio(p_clave text)
returns boolean
language sql volatile security definer set search_path = public
as $$ select public.clave_ok(p_clave); $$;

create or replace function public.agenda_dia(p_clave text, p_fecha date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'citas', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'fecha', c.fecha, 'hora', to_char(c.hora, 'HH24:MI'),
                                        'nombre', c.nombre, 'estado', c.estado, 'aviso_en', c.aviso_en) order by c.hora)
    from public.citas c where c.fecha = p_fecha), '[]'::jsonb));
end;
$$;

create or replace function public.marcar_cita(p_clave text, p_id uuid, p_estado text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  if p_estado not in ('pendiente', 'camino', 'no_va', 'llego') then return jsonb_build_object('ok', false); end if;
  update public.citas set estado = p_estado, aviso_en = now() where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- Guarda la lista de un día: reemplaza la anterior y conserva los avisos ya hechos
create or replace function public.guardar_citas(p_clave text, p_citas jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  viejas jsonb;
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into viejas
    from public.citas c
   where c.fecha in (select distinct (r ->> 'fecha')::date from jsonb_array_elements(p_citas) r);
  delete from public.citas
   where fecha in (select distinct (r ->> 'fecha')::date from jsonb_array_elements(p_citas) r);
  insert into public.citas (fecha, hora, nombre, estado, aviso_en)
  select (n ->> 'fecha')::date, (n ->> 'hora')::time, trim(n ->> 'nombre'),
         coalesce(v.estado, 'pendiente'), v.aviso_en
    from jsonb_array_elements(p_citas) n
    left join jsonb_to_recordset(viejas) as v(fecha date, hora time, nombre text, estado text, aviso_en timestamptz)
      on v.fecha = (n ->> 'fecha')::date and v.hora = (n ->> 'hora')::time
     and public.norm_txt(v.nombre) = public.norm_txt(n ->> 'nombre')
   where trim(coalesce(n ->> 'nombre', '')) <> '';
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.entrar_consultorio(text) to anon, authenticated;
grant execute on function public.agenda_dia(text, date) to anon, authenticated;
grant execute on function public.marcar_cita(text, uuid, text) to anon, authenticated;
grant execute on function public.guardar_citas(text, jsonb) to anon, authenticated;
