# Appagón · Asistente offline para apagones

**El problema.** Durante un apagón, millones de hogares se quedan sin internet ni información fiable y toman malas decisiones con su comida, su agua y sus baterías. Los chatbots necesitan red justo cuando no la hay.

**La solución.** Una app de iPhone que responde esas preguntas **sin conexión**. El modelo, las guías oficiales y los cálculos viven en el móvil.

## Resultados

Set de test de 56 preguntas que nunca se usó para desarrollar ni entrenar. Juez: Muse Glimmer 30B, de otra familia que los modelos evaluados.

| | Correctas | Correctas + parciales | Peligrosas | Tokens por respuesta |
|---|---|---|---|---|
| Mejor modelo pequeño sin guías (línea base)* | 23 % | 83 % | 6 | 39 |
| Ministral 3 3B + asistente completo | 62 % | 91 % | 3 | 87 |
| **Ministral 3 3B afinado + asistente completo (la app)** | **52 %** | **93 %** | **1** | **44** |

\* Gemma 4 E2B, medido en el set de desarrollo (94 preguntas).

**En un iPhone 16, en modo avión:** ~7–9 s hasta la primera palabra, 10–16 tokens/s y 3 GB de memoria como máximo.

## Cómo funciona

```
pregunta → reglas de seguridad → calculadoras → búsqueda en las guías → modelo redacta la respuesta
```

1. **Reglas de seguridad** fijas en código para lo que no puede fallar: generador, monóxido, gas, medicamentos, lejía, pila de botón… (`eval/pipeline.py`).
2. **Calculadoras** deterministas: horas de nevera y congelador, litros y días de agua, cargas de power bank.
3. **RAG local**: las guías que cita el golden set (41 enlaces: CDC, AESAN, Sanidad, comunidades autónomas, Bomberos de Madrid, Cruz Roja, OCU…), troceadas e indexadas con EmbeddingGemma (`rag/`). Las guías españolas tienen prioridad.
4. **Modelo**: Ministral 3 3B afinado con QLoRA para responder corto y en texto plano (`finetune/`). GGUF Q4_K_M de 2,1 GB, ejecutado con llama.cpp.

## Decisiones clave

- **Por qué un modelo pequeño y local:** tiene que funcionar sin red y caber en un móvil. Se compararon 4 modelos de 2–3B; sin guías, ninguno pasa del 23 % de correctas.
- **Por qué Ministral 3 3B:** en el set de test generaliza mejor que Gemma 4 E2B (62 % frente a 48 %) con la misma seguridad. Además es europeo y Apache 2.0. La regla de decisión se escribió antes de ver los resultados.
- **Por qué fine-tuning:** la mitad de tokens (de 87 a 44 por respuesta), unos 4 s menos de espera en el móvil y menos respuestas peligrosas. A cambio, algunas «correctas» pasan a «parciales» porque resume más.
- **Por qué reglas y calculadoras en código:** un modelo de 3B se equivoca con las cifras y con la seguridad. Lo que es exacto no se le deja al modelo, y la app muestra el dato calculado si la respuesta no lo recoge.

## Limitaciones conocidas

- Android sin probar (no hay dispositivo). El GGUF y llama.cpp son los mismos; en un móvil de 4 GB de RAM probablemente no cabe.
- Fallos conocidos en la categoría de comunicación; el más serio: a «mi familia no contesta» responde «llama al 112», cuando con las líneas saturadas no hay que hacerlo.
- El juez varía unos ±3 puntos con las mismas respuestas, y con 56 preguntas el margen de error es de unos ±8 puntos.

## Estructura

| Carpeta | Qué hay |
|---|---|
| `data/` | Golden set de desarrollo (94 preguntas) y set de test (56), con respuesta de referencia y fuente |
| `eval/` | Línea base, asistente completo (`pipeline.py`), juez y tabla de resultados |
| `rag/` | Descarga de las guías y construcción del índice |
| `finetune/` | Datos sintéticos, cuaderno de Colab y Modelfile ([README](finetune/README.md)) |
| `movil/` | Prueba de riesgo en el iPhone y mediciones |
| `app/` | App iOS en SwiftUI + llama.cpp ([README](app/README.md)) |
| `results/` | Salidas de todas las evaluaciones; resumen en [`results/resumen.md`](results/resumen.md) |

## Reproducir

Requisitos: Mac con Apple Silicon, Python 3 y [Ollama](https://ollama.com).

```bash
ollama pull gemma4:e2b && ollama pull ministral-3:3b && ollama pull embeddinggemma
pip3 install --user pypdf
# juez: muse-glimmer:30b-mlx (se puede cambiar con la variable JUDGE)

python3 eval/run_baseline.py     # línea base sin guías → results/baseline_*.csv
python3 rag/build_index.py       # descarga las guías y crea rag/index.json
python3 eval/run_rag.py          # asistente completo → results/rag_*.csv
python3 eval/run_rag.py --test   # set de test (una sola vez, al final)
python3 eval/judge.py            # juez LLM → *_juzgado.csv
python3 eval/summary.py          # tabla → results/resumen.md
```

Todo con temperatura 0, semilla 42 y sin modo razonamiento. La app se prepara con `bash app/preparar.sh` (ver [`app/README.md`](app/README.md)).

## Enlaces

- Modelo afinado: [cocoataster/ministral3-apagon-GGUF](https://huggingface.co/cocoataster/ministral3-apagon-GGUF)
- Buscador: [ggml-org/embeddinggemma-300M-GGUF](https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF)

## Derechos

Las guías son de sus autores. El repo no incluye los documentos originales (`data/guias/` queda fuera y `rag/build_index.py` los descarga), pero `rag/index.json` y los datos de `finetune/data/` contienen fragmentos de su texto para que el asistente funcione y el entrenamiento se pueda revisar. Cada fragmento conserva su fuente. Los datos de entrenamiento se generaron antes de limpiar el índice, así que algunos ejemplos aún contienen texto de webs que no es guía (publicidad o noticias); el índice que usa la app ya está limpio. No se publican las respuestas en bruto del generador ni el índice anterior a la limpieza.

El código está bajo licencia [MIT](LICENSE). La licencia no cubre el texto de las guías ni sus fragmentos, que siguen siendo de sus autores.

---

Proyecto final del Programa Técnico Avanzado (PTA), noviembre de 2026.
