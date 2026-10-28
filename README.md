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

## Atajos

⌘K ir a / comando · ⌘F buscar aquí · ⌘⇧F buscar en todo · ⌘⌥↑↓ conversación
anterior/siguiente · ⌘⌥⇧↓ siguiente sin leer · ⌘⇧W cerrar conversación ·
⌘⌥0 reparto · ⌘+/⌘− tamaño · ⌘⇧P modo privado · ⌘⌥L protocolo ·
Tab completa (rota) · ↑↓ historial · ⇧↩ nueva línea · Esc cancela respuesta.
