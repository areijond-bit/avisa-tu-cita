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
-- ============================================================
-- PACIENTES Y WHATSAPP
-- Directorio de pacientes con teléfono. Si dos se llaman igual, "num" los distingue
-- (Juan Pérez (1), Juan Pérez (2)); eso solo lo ve el consultorio.
-- Cada cita tiene un "token": el link personal que se manda por WhatsApp.
-- ============================================================
create table if not exists public.pacientes (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  num        int not null default 1,
  telefono   text,
  creado_en  timestamptz not null default now()
);
create unique index if not exists pacientes_nombre_num on public.pacientes (public.norm_txt(nombre), num);
alter table public.pacientes enable row level security;
revoke all on public.pacientes from anon, authenticated;

alter table public.citas add column if not exists paciente_id uuid references public.pacientes (id) on delete set null;
alter table public.citas add column if not exists token uuid not null default gen_random_uuid();
alter table public.citas add column if not exists enviado_en timestamptz;
create unique index if not exists citas_token on public.citas (token);

-- Siguiente número libre para un nombre (1 si nadie se llama así)
create or replace function public.siguiente_num(p_nombre text, p_sin uuid default null)
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce(max(num), 0) + 1 from public.pacientes
   where public.norm_txt(nombre) = public.norm_txt(p_nombre) and (p_sin is null or id <> p_sin);
$$;
revoke all on function public.siguiente_num(text, uuid) from public, anon, authenticated;

-- Paciente: abrir su cita desde el link de WhatsApp
create or replace function public.cita_por_token(p_token uuid)
returns table (id uuid, fecha date, hora time, nombre text, estado text)
language sql stable security definer set search_path = public
as $$
  select c.id, c.fecha, c.hora, coalesce(p.nombre, c.nombre), c.estado
    from public.citas c left join public.pacientes p on p.id = c.paciente_id
   where c.token = p_token
     and c.fecha >= (now() at time zone 'America/Mexico_City')::date;
$$;
revoke all on function public.cita_por_token(uuid) from public;
grant execute on function public.cita_por_token(uuid) to anon, authenticated;

create or replace function public.agenda_dia(p_clave text, p_fecha date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'citas', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'fecha', c.fecha, 'hora', to_char(c.hora, 'HH24:MI'),
             'nombre', coalesce(p.nombre, c.nombre), 'estado', c.estado, 'aviso_en', c.aviso_en,
             'token', c.token, 'enviado_en', c.enviado_en, 'paciente_id', c.paciente_id,
             'telefono', p.telefono, 'num', p.num,
             'dup', (select count(*) from public.pacientes p2 where public.norm_txt(p2.nombre) = public.norm_txt(p.nombre))
           ) order by c.hora)
      from public.citas c left join public.pacientes p on p.id = c.paciente_id
     where c.fecha = p_fecha), '[]'::jsonb));
end;
$$;

-- Guarda la lista de un día. Liga cada nombre con su paciente (o lo da de alta)
-- y conserva avisos, links y mensajes ya enviados de quien ya estaba en la lista.
create or replace function public.guardar_citas(p_clave text, p_citas jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  viejas jsonb;
  fechas date[];
  r jsonb;
  nm text;
  pid uuid;
  n int;
  nuevos int := 0;
  total int := 0;
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  fechas := array(select distinct (x ->> 'fecha')::date from jsonb_array_elements(p_citas) x);
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into viejas from public.citas c where c.fecha = any (fechas);
  delete from public.citas where fecha = any (fechas);

  for r in select * from jsonb_array_elements(p_citas) loop
    nm := trim(coalesce(r ->> 'nombre', ''));
    continue when nm = '';
    pid := nullif(r ->> 'paciente_id', '')::uuid;
    if pid is null and not coalesce((r ->> 'nuevo')::boolean, false) then
      select count(*) into n from public.pacientes p where public.norm_txt(p.nombre) = public.norm_txt(nm);
      if n = 1 then select p.id into pid from public.pacientes p where public.norm_txt(p.nombre) = public.norm_txt(nm); end if;
    end if;
    if pid is null then
      insert into public.pacientes (nombre, num) values (nm, public.siguiente_num(nm)) returning id into pid;
      nuevos := nuevos + 1;
    end if;
    total := total + 1;

    insert into public.citas (fecha, hora, nombre, paciente_id, estado, aviso_en, token, enviado_en)
    select (r ->> 'fecha')::date, (r ->> 'hora')::time, nm, pid,
           coalesce(v.estado, 'pendiente'), v.aviso_en, coalesce(v.token, gen_random_uuid()), v.enviado_en
      from (select 1) uno
      left join lateral (
        select * from jsonb_to_recordset(viejas)
          as v(fecha date, nombre text, paciente_id uuid, estado text, aviso_en timestamptz, token uuid, enviado_en timestamptz)
         where v.fecha = (r ->> 'fecha')::date
           and (v.paciente_id = pid or (v.paciente_id is null and public.norm_txt(v.nombre) = public.norm_txt(nm)))
           and not exists (select 1 from public.citas c2 where c2.token = v.token)
         limit 1
      ) v on true;
  end loop;
  return jsonb_build_object('ok', true, 'citas', total, 'nuevos', nuevos);
end;
$$;

create or replace function public.marcar_enviado(p_clave text, p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  update public.citas set enviado_en = now() where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.pacientes_lista(p_clave text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'pacientes', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'nombre', p.nombre, 'num', p.num, 'telefono', p.telefono,
             'dup', (select count(*) from public.pacientes p2 where public.norm_txt(p2.nombre) = public.norm_txt(p.nombre))
           ) order by public.norm_txt(p.nombre), p.num)
      from public.pacientes p), '[]'::jsonb));
end;
$$;

-- Alta o cambio de un paciente. Con p_cita, además liga esa cita con el paciente.
create or replace function public.paciente_guardar(p_clave text, p_id uuid, p_nombre text, p_telefono text, p_cita uuid default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  nm text := trim(coalesce(p_nombre, ''));
  tel text := nullif(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'), '');
  pid uuid := p_id;
  antes text;
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  if length(nm) < 2 then return jsonb_build_object('ok', true, 'error', 'Falta el nombre.'); end if;
  if pid is null then
    insert into public.pacientes (nombre, num, telefono) values (nm, public.siguiente_num(nm), tel) returning id into pid;
  else
    select nombre into antes from public.pacientes where id = pid;
    update public.pacientes
       set nombre = nm, telefono = tel,
           num = case when public.norm_txt(antes) = public.norm_txt(nm) then num else public.siguiente_num(nm, pid) end
     where id = pid;
  end if;
  if p_cita is not null then
    update public.citas set paciente_id = pid where id = p_cita;
  end if;
  return jsonb_build_object('ok', true, 'id', pid);
end;
$$;

create or replace function public.paciente_borrar(p_clave text, p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not public.clave_ok(p_clave) then return jsonb_build_object('ok', false); end if;
  delete from public.pacientes where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.marcar_enviado(text, uuid) to anon, authenticated;
grant execute on function public.pacientes_lista(text) to anon, authenticated;
grant execute on function public.paciente_guardar(text, uuid, text, text, uuid) to anon, authenticated;
grant execute on function public.paciente_borrar(text, uuid) to anon, authenticated;
