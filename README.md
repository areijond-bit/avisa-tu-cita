# Avisa tu Cita

Página para que los pacientes del consultorio del Dr. Alejandro Alba confirmen o cancelen su cita, y panel para que el doctor y su asistente lleven la agenda del día.

- Pacientes: https://areijond-bit.github.io/avisa-tu-cita/
- Panel del consultorio: https://areijond-bit.github.io/avisa-tu-cita/#consultorio

## Cómo está armado

Es una página estática (sin servidor propio) publicada con GitHub Pages. Los datos viven en Supabase (Postgres).

```
index.html      estructura de la página
css/app.css     estilos
js/app.js       toda la lógica (paciente y panel)
db/schema.sql   tablas, reglas y funciones de la base de datos
```

Librerías que se cargan desde CDN:

- `@supabase/supabase-js` 2.45.4: conexión a la base de datos y avisos en vivo.
- `qrcodejs` 1.0.0: el QR del cartel.
- `tesseract.js` 5.1.0: lee la foto de la lista de citas en el mismo navegador.

No hay paso de compilación. Para probar en local basta con servir la carpeta, por ejemplo `npx serve .`.

## Base de datos

`db/schema.sql` se puede correr completo en Supabase → SQL Editor, y se puede volver a correr sin perder datos.

Tablas:

| Tabla | Para qué |
|---|---|
| `citas` | fecha, hora, nombre, estado (`pendiente`, `camino`, `no_va`, `llego`), link personal (`token`), si ya se mandó el WhatsApp |
| `pacientes` | nombre y teléfono. `num` distingue a dos pacientes con el mismo nombre |
| `ajustes` | la contraseña del panel, cifrada con bcrypt |
| `intentos` | intentos fallidos de contraseña (bloquea 15 min después de 20) |

Seguridad:

- Nadie lee las tablas directamente: `anon` no tiene permisos sobre ellas.
- El paciente solo puede usar `buscar_cita` (pide nombre y apellido), `cita_por_token` (su link personal) y `avisar_cita` (confirmar o cancelar).
- Todo lo del panel pasa por funciones `security definer` que reciben la contraseña y la revisan con `clave_ok` antes de hacer algo.
- La llave que está en `js/app.js` es la llave pública (`anon`) de Supabase. Está hecha para ir en el navegador; la llave `service_role` no está en el código.

Cambiar la contraseña del panel (correr aparte, no guardarla en el repositorio):

```sql
insert into public.ajustes (id, clave_hash)
values (1, extensions.crypt('NUEVA-CONTRASEÑA', extensions.gen_salt('bf')))
on conflict (id) do update set clave_hash = excluded.clave_hash;
```

## Configuración

Arriba de `js/app.js`:

- `CONFIG`: URL y llave pública de Supabase.
- `CLINIC`: nombre del doctor, iniciales y el título que aparece en la página y en los mensajes de WhatsApp.
- `SITE_URL`: dirección pública de la página (se usa en los links de WhatsApp y en el QR).
- `HORARIO`: de 8:00 a 14:00, una cita cada 15 minutos (24 lugares).

## Cómo funciona

1. La asistente carga la lista del día (foto, texto pegado o a mano). Los nombres nuevos se dan de alta solos en `pacientes`.
2. Desde la agenda se manda a cada paciente un WhatsApp con su link personal (`?c=<token>`). Se usa `wa.me` en celular y WhatsApp Web en computadora, siempre en la misma pestaña; no hay envío automático.
3. El paciente abre el link y confirma o cancela.
4. Los cambios se avisan entre pantallas abiertas con un canal *broadcast* de Supabase Realtime, y además la agenda se recarga cada 15 segundos.

## Pendiente

- El envío de WhatsApp es manual (un clic por paciente). Para que sea automático hace falta la API de WhatsApp Business de Meta, con un número propio y costo por mensaje.

## Al publicar un cambio

En `index.html`, `css/app.css` y `js/app.js` llevan `?v=AAAAMMDDHHMM`. Cambiar ese número en cada publicación obliga a los navegadores a bajar la versión nueva en lugar de usar la guardada.
