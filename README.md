# Keryx

Cliente de IRC para macOS en SwiftUI. Las conversaciones se componen como un
guion: el nick en versalitas seguido de lo que dice, y en cursiva las
acotaciones (entradas, salidas, cambios de nick, `/me`). El titular del canal
es el título del acto y **⁂** marca dónde empieza lo nuevo.

Lo que escribes va a lápiz (grafito) y pasa a tinta cuando el servidor lo
confirma (`echo-message` + `labeled-response`).

## IRCv3

`message-tags`, `server-time`, `batch` (incluidos `netsplit`/`netjoin`),
`labeled-response`, `echo-message`, `cap-notify`, `standard-replies`,
`account-tag`, `account-notify`, `away-notify`, `chghost`, `extended-join`,
`setname`, `invite-notify`, `multi-prefix`, `userhost-in-names`,
`no-implicit-names` (y la de soju), `sts`, `sasl` (PLAIN, EXTERNAL/CertFP,
SCRAM-SHA-256 automático), `draft/sasl-ir`, `draft/chathistory` (LATEST,
BEFORE, AFTER, AROUND, TARGETS), `draft/event-playback`, `draft/multiline`
(envío y recepción), `draft/read-marker`, `draft/message-redaction`,
`+typing`, `+draft/react`/`+draft/unreact`, `+reply`/`+draft/reply`,
`draft/metadata-2` (perfiles; en soju, sincroniza ignorados, silenciados y
fijados), MONITOR + `extended-monitor` (contactos), `soju.im/bouncer-networks`
(una sesión por red del bouncer), FILEHOST, CLIENTTAGDENY, WHOX, modo bot.

## Estructura

```
KeryxProtocol/   Paquete SPM puro: parser, tags, CAP/SASL, SCRAM, STS, ISUPPORT (swift test)
Keryx/
  Transport/     NWConnection + TLS/CertFP
  Session/       Sesión: registro, despacho, historial, social, comandos
  Model/         Redes (JSON + llavero), estado por red, STS, historial en disco
  Services/      Notificaciones, búsqueda FTS5, subidas, resolución de enlaces
  Design/        Paleta y tipografía
  Views/         Guion, composer, barra lateral, reparto, hojas
KeryxTests/      Sesión con transporte falso, maquetación del guion
```

## Compilar

```sh
xcodegen generate
xcodebuild -project Keryx.xcodeproj -scheme Keryx test
(cd KeryxProtocol && swift test)
```

En Debug, `-KeryxDemo` abre una escena de ejemplo sin conectar ni guardar nada.
Release se firma con Developer ID (hardened runtime), lista para notarizar.

## /np (lo que suena)

macOS no deja a apps de terceros leer el «Ahora suena» de la barra de menús
desde la versión 15.4, así que `/np` pregunta a los reproductores por vías
públicas: Música y Spotify por AppleScript (solo si ya están abiertos) y
cualquier reproductor que hable este protocolo, como Zplayer.

**Protocolo.** El reproductor publica la notificación distribuida
`im.keryx.NowPlaying` cuando cambia la pista o el estado, y también cada vez
que recibe `im.keryx.NowPlaying.request`. El contenido va como cadena JSON en
el `object` de la notificación (las apps con sandbox no pueden enviar
`userInfo`):

```json
{"player": "Zplayer", "title": "…", "artist": "…", "album": "…", "playing": true, "video": false}
```

Sin `title` significa que no suena nada en ese reproductor.

## /exec (tus scripts)

Keryx va con sandbox, así que `/exec` solo ejecuta los scripts que tú pongas en
`~/Library/Application Scripts/im.keryx.mac/` (la vía que macOS da a las apps
con sandbox; Keryx no puede escribir ahí). Se ejecutan fuera del sandbox, con
tus permisos.

- `/exec` lista tus scripts y explica cómo empezar.
- `/exec nombre args…` muestra la salida solo a ti.
- `/exec -o nombre args…` la envía a la conversación (confirma si son más de 5 líneas).
- `/exec -kill` deja de esperar (macOS no deja a Keryx matar el proceso).

Para tener el `/exec` de WeeChat con cualquier comando, crea un script `sh`:

```sh
D=~/Library/Application\ Scripts/im.keryx.mac
printf '#!/bin/sh\nexec /bin/sh -c "$*"\n' > "$D/sh" && chmod +x "$D/sh"
```

Y luego `/exec sh uptime` o `/exec -o sh uname -a`.

## Atajos

⌘K ir a / comando · ⌘F buscar aquí · ⌘⇧F buscar en todo · ⌘⌥↑↓ conversación
anterior/siguiente · ⌘⌥⇧↓ siguiente sin leer · ⌘⇧W cerrar conversación ·
⌘⌥0 reparto · ⌘+/⌘− tamaño · ⌘⇧P modo privado · ⌘⌥L protocolo ·
Tab acepta la sugerencia en gris y rota entre candidatos · → al final la acepta ·
⌥S corrige la palabra mal escrita más cercana · ↑↓ historial · ⇧↩ nueva línea ·
Esc cancela respuesta.

El composer sugiere nicks (primero quien ha hablado hace poco), `/comandos`,
`#canales` y palabras del diccionario de macOS a partir de tres letras. El
corrector del sistema subraya las erratas; `/lang es`, `/lang en`, `/lang auto`
u `/lang off` elige el idioma por conversación.
