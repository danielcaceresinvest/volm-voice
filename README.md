# VOLM Voice — Mónica en tu Mac

Asistente de voz para macOS. Dices «Mónica», le hablas en español y te contesta con una voz natural de Siri. El cerebro es un agente de [OpenClaw](https://github.com/openclaw/openclaw): Mónica puede leer tu correo, mirar tu agenda, buscar en la web o usar el ordenador, según las herramientas que tenga tu agente.

El reconocimiento de voz y la síntesis se hacen en tu Mac. Lo que le pides sale hacia el modelo que tenga configurado OpenClaw.

## Requisitos

- Mac con Apple Silicon y **macOS 26** o posterior.
- **Xcode** o las Command Line Tools con Swift 6 (`xcode-select --install`).
- **OpenClaw** instalado y configurado, con el comando `openclaw` en `/opt/homebrew/bin`, `/usr/local/bin` o `~/.local/bin`. Comprueba que `openclaw acp` funciona en la terminal.
- Una **voz de Siri en español** descargada: Ajustes del Sistema › Accesibilidad › Contenido leído › Voz del sistema › Gestionar voces. Por defecto se usa `com.apple.siri.natural.Luisa`.

## Instalación

```bash
git clone https://github.com/danielcaceresinvest/volm-voice.git
cd volm-voice
./make-cert.sh   # una sola vez: certificado local para que macOS recuerde los permisos
./build.sh       # compila e instala en ~/Applications/VOLM Voice.app
open ~/Applications/"VOLM Voice.app"
```

La primera vez macOS pide permiso para el micrófono y el reconocimiento de voz. Mónica aparece en la barra de menús.

`make-cert.sh` crea un certificado autofirmado «VOLM Dev» en tu llavero. Es opcional: sin él la app se firma ad hoc y macOS vuelve a pedir los permisos tras cada compilación.

## Uso

- «Mónica, ¿qué tiempo hace en Sevilla?» — la palabra de activación y la pregunta pueden ir juntas.
- Tras la respuesta hay unos segundos para seguir hablando sin repetir su nombre.
- «Mónica, cállate» la interrumpe. «Gracias, Mónica» cierra la conversación.
- Desde el menú: hablar ahora, pausar la escucha, reconectar con OpenClaw, modo clase (ventana grande para proyector).

Opciones de arranque: `--demo` recorre todos los estados sin micrófono ni OpenClaw, `--stage` abre el modo clase.

## Configuración

`~/Library/Application Support/VOLM Voice/config.json` se crea al primer arranque. Campos útiles:

| Campo | Para qué |
| --- | --- |
| `wakeWords` | Palabras de activación, sin tildes (`["oye monica", "monica"]`). Cámbialas para que tu asistente se llame de otra forma. |
| `voiceId` | Identificador de la voz del sistema. |
| `locale` | Idioma del reconocimiento (`es_ES`). |
| `sessionKey` | Sesión de OpenClaw a la que habla (`agent:main:voz`). |
| `followUpSeconds` | Segundos para seguir hablando tras una respuesta. |
| `briefingEnabled`, `briefingHour`, `briefingMinute`, `briefingPrompt` | Resumen de la mañana automático. |
| `urlKey` | Secreto para los enlaces `volm-voice://ask` y `volm-voice://say`. Se genera solo; no lo compartas. |

Reinicia la app tras editar el archivo.

### Enlaces

- `volm-voice://listen`, `volm-voice://stop`, `volm-voice://stage`
- `volm-voice://ask?key=<urlKey>&q=<pregunta>` — le pregunta algo.
- `volm-voice://say?key=<urlKey>&text=<texto>` — dice un aviso en voz alta (útil para tareas en segundo plano).

## Tipografía

La interfaz está diseñada con Suisse Int'l, una fuente de pago que **no** se incluye en el repositorio. Sin ella se usa la fuente del sistema. Si tienes licencia, copia los `.otf` en `Resources/Fonts/` antes de ejecutar `./build.sh`.

## Desarrollo

```bash
swift build
swift test
```

`VOLMVoiceCore` contiene la lógica sin dependencias de interfaz (conversación, palabra de activación, protocolo ACP, troceo en frases) y está cubierta por tests. `VOLMVoice` es la app: audio, reconocimiento, voz, isla y orbe.

Logs en `~/Library/Logs/VOLM Voice/volm-voice.log`.

## Contribuir

El proyecto es de la comunidad. Lee [CONTRIBUTING.md](CONTRIBUTING.md) y abre un issue o un pull request.

## Licencia

[GPL-3.0](LICENSE). Puedes usar, estudiar, modificar y compartir el código. Si distribuyes una versión modificada, debe publicarse también bajo GPL-3.0, con su código fuente.
