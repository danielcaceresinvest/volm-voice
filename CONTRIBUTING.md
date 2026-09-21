# Contribuir

Gracias por querer mejorar Mónica. Cualquier aportación es bienvenida: código, pruebas, documentación, traducciones o ideas.

## Cómo empezar

1. Abre un issue antes de un cambio grande, para hablarlo primero.
2. Haz un fork y crea una rama desde `main`.
3. Comprueba que todo compila y que los tests pasan:
   ```bash
   swift build
   swift test
   ```
4. Abre un pull request explicando qué cambia y por qué.

## Pautas

- La lógica sin interfaz va en `VOLMVoiceCore` y lleva tests.
- Sigue el estilo del código que ya existe.
- No subas fuentes de pago, claves ni datos personales.
- Para un fallo, adjunta las líneas relevantes de `~/Library/Logs/VOLM Voice/volm-voice.log`.

## Licencia

VOLM Voice se publica bajo GPL-3.0. Al contribuir, aceptas que tu código se distribuya con esa licencia. Cualquier versión modificada que se distribuya debe seguir siendo abierta.
