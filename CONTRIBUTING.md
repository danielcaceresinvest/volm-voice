# Contribuir

Gracias por querer mejorar Mónica. Cualquier aportación es bienvenida: código, pruebas, documentación, traducciones o ideas.

## Ramas

- `main`: versión estable. Protegida: nadie hace push directo, solo entra código por pull request aprobado y con los tests en verde.
- `develop`: integración. Aquí llegan todos los pull requests. Protegida igual que `main`.
- Ramas de trabajo, siempre desde `develop`:
  - `feature/<nombre>` para funciones nuevas (`feature/wake-word-ingles`).
  - `fix/<nombre>` para fallos (`fix/eco-voz`).
  - `docs/<nombre>` para documentación.

Cuando `develop` está estable, se abre un pull request de `develop` a `main` para publicar versión.

## Cómo empezar

1. Abre un issue antes de un cambio grande, para hablarlo primero.
2. Haz un fork y crea tu rama desde `develop`:
   ```bash
   git checkout develop
   git pull
   git checkout -b feature/mi-mejora
   ```
3. Comprueba que todo compila y que los tests pasan:
   ```bash
   swift build
   swift test
   ```
4. Abre un pull request **contra `develop`** explicando qué cambia y por qué. La CI ejecuta `swift build` y `swift test`; debe estar en verde.

## Pautas

- La lógica sin interfaz va en `VOLMVoiceCore` y lleva tests.
- Sigue el estilo del código que ya existe.
- No subas fuentes de pago, claves ni datos personales.
- Para un fallo, adjunta las líneas relevantes de `~/Library/Logs/VOLM Voice/volm-voice.log`.

## Licencia

VOLM Voice se publica bajo GPL-3.0. Al contribuir, aceptas que tu código se distribuya con esa licencia. Cualquier versión modificada que se distribuya debe seguir siendo abierta.
