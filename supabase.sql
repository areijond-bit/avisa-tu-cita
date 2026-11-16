-- Avisa tu Cita: base de datos para Supabase.
-- Pegar completo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
--
-- Qué se guarda: nombre, últimos 4 números del seguro social, fecha, hora y estado.
-- Nada médico y nunca el número de seguro social completo.
--
-- Quién puede hacer qué:
--   * Pacientes (sin cuenta): solo pueden buscar SU cita con nombre + 4 números
--     y avisar "en camino" / "no va". No pueden ver la lista de pacientes.
--   * Personal (doctor y asistente): entran con correo y contraseña y ven/editan todo,
--     pero solo si su correo está en la tabla "personal" (al final de este archivo).

create table if not exists public.citas (
  id         uuid primary key default gen_random_uuid(),
  fecha      date not null,
  hora       time not null,
  nombre     text not null,
  nss4       text not null check (nss4 ~ '^[0-9]{4}$'),
  estado     text not null default 'pendiente' check (estado in ('pendiente', 'camino', 'no_va', 'llego')),
  aviso_en   timestamptz,
  creado_en  timestamptz not null default now(),
  unique (fecha, hora, nss4)
);
create index if not exists citas_fecha on public.citas (fecha);

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

-- Paciente: buscar su cita (de hoy en adelante) con nombre + 4 números
create or replace function public.buscar_cita(p_nombre text, p_nss4 text)
returns table (id uuid, fecha date, hora time, nombre text, estado text)
language plpgsql stable security definer set search_path = public
as $$
declare
  palabras text[];
  hoy date := (now() at time zone 'America/Mexico_City')::date;
begin
  if p_nss4 is null or p_nss4 !~ '^[0-9]{4}$' then return; end if;
  palabras := array(
    select w from regexp_split_to_table(public.norm_txt(p_nombre), '\s+') as w where length(w) >= 2
  );
  if coalesce(array_length(palabras, 1), 0) = 0 then return; end if;

  return query
    select c.id, c.fecha, c.hora, c.nombre, c.estado
    from public.citas c
    where c.nss4 = p_nss4
      and c.fecha >= hoy
      and not exists (
        select 1 from unnest(palabras) as q
        where not exists (
          select 1 from regexp_split_to_table(public.norm_txt(c.nombre), '\s+') as n
          where n like q || '%'
        )
      )
    order by c.fecha, c.hora
    limit 5;
end;
$$;

-- Paciente: avisar "camino" o "no_va". Pide otra vez los 4 números.
create or replace function public.avisar_cita(p_id uuid, p_nss4 text, p_estado text)
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
     and nss4 = p_nss4
     and estado <> 'llego'
     and fecha >= (now() at time zone 'America/Mexico_City')::date
  returning estado into nuevo;
  return nuevo;
end;
$$;

revoke all on function public.buscar_cita(text, text) from public;
revoke all on function public.avisar_cita(uuid, text, text) from public;
grant execute on function public.buscar_cita(text, text) to anon, authenticated;
grant execute on function public.avisar_cita(uuid, text, text) to anon, authenticated;

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
-- PERSONAL DEL CONSULTORIO: cambia estos correos por los reales
-- (los mismos con los que crearás los usuarios en Authentication → Users)
-- ============================================================
insert into public.personal (email) values
  ('correo-del-doctor@ejemplo.com'),
  ('correo-de-la-asistente@ejemplo.com')
on conflict do nothing;
