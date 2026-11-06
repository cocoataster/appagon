# Paso 6 · App iOS (SwiftUI + llama.cpp)

El mismo asistente que se evaluó en Python, dentro del iPhone y sin conexión:

1. **Reglas de seguridad, sinónimos y mensaje de sistema**: se exportan de `eval/pipeline.py` a `Contenido/datos/reglas.json` (una sola fuente de verdad).
2. **Calculadoras**: escritas en Swift (`Sources/Pipeline.swift`) y comprobadas contra Python con `casos.json`.
3. **Búsqueda en las guías**: EmbeddingGemma (GGUF, con llama.cpp) convierte la pregunta en un vector y se compara con `index.json` (431 trozos). Máximo 2 trozos por guía, las españolas primero.
4. **Modelo**: Ministral 3 3B afinado (`ministral3-apagon.Q4_K_M.gguf`, 2,1 GB), temperatura 0, como en la evaluación. Mismo formato de mensaje que la plantilla de Ministral 3 en Ollama.

**Los modelos no van dentro de la app.** La app pesa ~5 MB (índice de las guías, reglas y casos de prueba). La primera vez pide descargar los dos modelos (2,4 GB) de Hugging Face, **con Wi-Fi y antes de un apagón**: barra de progreso, comprueba el espacio libre, sigue donde iba si se corta («Reintentar») y comprueba la huella SHA-256 de cada archivo. Se guardan en *Application Support* fuera de la copia de iCloud. Ajustes → Desarrollador → «Borrar modelos descargados» para volver a probar la descarga.

- Asistente: [`cocoataster/ministral3-apagon-GGUF`](https://huggingface.co/cocoataster/ministral3-apagon-GGUF) (subido a mano desde la web el 2 nov; el nombre del repo está en `app/hf_repo.txt`).
- Buscador: `ggml-org/embeddinggemma-300M-GGUF` (`embeddinggemma-300M-Q8_0.gguf`).
- Al lanzar desde Xcode (simulador o «My Mac»), la variable `APAGON_MODELOS` apunta a `app/Modelos` y la app usa esos archivos sin descargarlos (si el sistema le deja leerlos).

Mejoras para el móvil:
- El mensaje de sistema se lee una vez y se reutiliza entre preguntas (solo se lee la parte nueva).
- Se quitan los guiones de corte de línea que el modelo copia de los PDF («in-mediato»).
- **Red de seguridad de las cifras:** si hay un dato calculado (margen de nevera, litros, cargas, días) y la respuesta del modelo no lo recoge o da otra cifra, la app muestra debajo «Dato calculado: …» con el resultado de la calculadora. Si el límite de la nevera ya se ha superado, comprueba que la respuesta lo diga. Se añadió tras ver en el simulador «4 horas de margen» en vez de 1 h. Casos de prueba en `Verification.safetyNet` (los ejecuta `check` y la Autocomprobación).
- Indicador «Pensando… leyendo las guías (N s)» mientras lee el contexto, botón fijo de 112, pantalla oscura.
- Debajo de cada respuesta: cálculo, fuentes consultadas y tiempos (búsqueda, 1.ª palabra, tokens/s).

## Preparar (en el Mac, una vez)

```bash
cd ~/Documents/PTA/"PTA - Eric Sans"/proyecto-apagon
bash app/preparar.sh
```

El script instala `cmake` y `xcodegen` si faltan, compila llama.cpp para iOS (versión fija `b12038`, ~10–20 min la primera vez), copia los dos modelos, exporta los datos desde `eval/pipeline.py`, comprueba en Swift que reglas y calculadoras dan lo mismo que en Python y genera `app/Apagon.xcodeproj`.

## Ejecutar en el simulador

1. Abre `app/Apagon.xcodeproj`.
2. Arriba, elige un simulador de iPhone (p. ej. iPhone 16) y pulsa ▶ (Cmd+R).
3. Al lanzar desde Xcode, la app usa los modelos de `app/Modelos` sin descargarlos (variable `APAGON_MODELOS`). Para probar la descarga: Ajustes → Desarrollador → «Borrar modelos descargados» → «Descargar ahora».
4. En la app: Ajustes → Desarrollador → **Autocomprobación**. Debe decir que reglas, calculadoras y sinónimos son iguales que en Python y cuántos trozos de la búsqueda coinciden con Ollama.

**Resultado (2 nov):** reglas, calculadoras y sinónimos iguales que en Python en 160 de 160 preguntas; búsqueda con 237 de 240 trozos iguales que con Ollama (37 de 40 preguntas idénticas).

EmbeddingGemma: el GGUF que guarda Ollama es arquitectura `gemma3` y llama.cpp no lo carga; `preparar.sh` descarga `embeddinggemma-300M-Q8_0.gguf` de ggml-org (arquitectura `gemma-embedding`).

En el simulador el modelo corre solo en CPU (sin GPU): los tiempos **no** son los del iPhone (la primera pregunta tardó más de 50 s en empezar a responder). Para probar rápido en el Mac con GPU: destino **My Mac (Designed for iPad)**.

**Descarga comprobada (2 nov)** en «My Mac»: borrar modelos → «Descargar ahora» baja los 2,4 GB de Hugging Face, comprueba las huellas SHA-256 y la app queda lista. Funcionó a la primera.

**Demo comprobada (2 nov)** en «My Mac (Designed for iPhone)», con GPU: menos de 2 s por respuesta. nevera → «1 hora de margen restante… no abras la nevera»; agua → «18 litros como mínimo para 3 días»; radio → «Sigue RNE en FM o DAB+… acércate a una ventana…». Iguales que con Ollama.

**Fragilidad encontrada:** en una pasada en el simulador (CPU) la nevera respondió «con **4** horas de margen restante» en vez de 1 h. La calculadora estaba bien («Margen restante = 4 h … − 3 h = 1 h»), pero el modelo copió el primer número. Los cálculos en CPU y en GPU dan números internos ligeramente distintos y eso basta para que elija otro.

## Ejecutar en el iPhone (otro Mac conectado al iPhone)

1. Copia la carpeta `proyecto-apagon` a ese Mac (o clona el repo) y ejecuta `bash app/preparar.sh` allí (o copia también `app/vendor`, `app/Modelos` y `app/Contenido/datos`).
2. En Xcode: proyecto **Apagon** → target **Apagon** → *Signing & Capabilities* → elige tu equipo (sirve una cuenta de Apple gratuita).
3. Conecta el iPhone, elígelo arriba y pulsa ▶. La primera vez, en el iPhone: Ajustes → General → VPN y gestión de dispositivos → confía en tu cuenta de desarrollador.
4. Abre la app **con Wi-Fi** y pulsa «Descargar ahora» (2,4 GB, deja la app abierta).
5. Pon el iPhone en **modo avión** y prueba las 3 preguntas de la demo. Apunta los tiempos que aparecen debajo de la respuesta en `movil/mediciones.csv`.

## Archivos

| Archivo | Qué es |
|---|---|
| `preparar.sh` | Prepara todo en el Mac |
| `exportar_datos.py` | Exporta reglas, índice y casos de prueba desde `eval/pipeline.py` |
| `project.yml` | Descripción del proyecto de Xcode (XcodeGen) |
| `Sources/Pipeline.swift` | Reglas, calculadoras, sinónimos, búsqueda y mensaje (sin el modelo) |
| `Sources/Models.swift` | Descarga de los modelos: progreso, reanudar, espacio libre y huella SHA-256 |
| `Sources/Llama.swift` | llama.cpp: el modelo que escribe y el de los vectores |
| `Sources/Assistant.swift` | Une las piezas, fuera del hilo de la interfaz |
| `Sources/ContentView.swift` | Pestañas, lista de chats y el chat (se abre en una hoja) |
| `Sources/Screens.swift` | Respuesta, guardadas e inventario (de momento solo la pantalla) |
| `Sources/History.swift` | Conversaciones y respuestas guardadas en el móvil (UserDefaults); solo se muestran, cada pregunta se responde por separado |
| `Sources/Connectivity.swift` | Estado de la conexión (NWPathMonitor): solo importa para descargar los modelos |
| `Sources/Settings.swift` | Pestaña Ajustes: modelos y su estado, guías consultadas y herramientas de desarrollo |
| `Sources/Category.swift` | Categoría de cada respuesta guardada, por palabras clave de la pregunta |
| `Sources/Theme.swift` | Colores de acento y del estado de la conexión; el resto, componentes nativos de iOS |
| `check/main.swift` | Comprobación de reglas y calculadoras contra Python, sin simulador |

No se suben al repo (`.gitignore`): `vendor/` (llama.cpp), `Modelos/` (GGUF), `Contenido/datos/` (se regenera), `build/` y `Apagon.xcodeproj` (se genera con XcodeGen).
