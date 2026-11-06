# Paso 5 · Fine-tuning de Ministral 3 3B

**Qué se enseña:** el estilo, no los datos (los datos los pone el RAG).

- Texto plano, 1–3 frases (objetivo: ~45 tokens en vez de ~90, la mitad de espera).
- Copiar el DATO CALCULADO sin rehacer la cuenta.
- En trampas sin regla fija: negarse y derivar sin rodeos.
- Si las guías no responden: decirlo sin inventar.

**Sin fuga de datos:** ninguna pregunta del golden set ni del set de test entra en el entrenamiento. `gen_data.py` descarta las preguntas generadas que se parezcan demasiado a cualquiera de ellas (similitud ≥ 0,88 con EmbeddingGemma).

## 1. Generar los datos (Mac, ~2,5 h, se puede cortar y reanudar)

```bash
python3 finetune/gen_data.py --limit 5    # prueba rápida
rm -rf finetune/data                      # borra la prueba
python3 finetune/gen_data.py              # completo
```

Muse Glimmer escribe ~400 preguntas a partir de las guías, ~120 trampas, ~40 sin respuesta y ~60 cálculos (≈ 600 ejemplos, ~2,5 h) con números aleatorios. Después escribe la respuesta ideal con **el mismo contexto que recibe la app** (reglas + calculadoras + RAG). Se descartan las respuestas con formato, de más de 70 palabras o sin la cifra calculada.

Salida en `finetune/data/`: `train.jsonl`, `valid.jsonl` y `revision.csv`.

**Antes de entrenar, revisa `revision.csv`** (50 ejemplos al azar): marca sí/no y comenta. Si hay muchos fallos, se corrige el generador y se vuelve a lanzar.

## 2. Entrenar (Google Colab, GPU T4 gratis, ~30–60 min)

Abre `finetune/train_colab.ipynb` en Colab, elige GPU T4 y ejecuta las celdas. Sube `train.jsonl` y `valid.jsonl` cuando te lo pida. Al final descarga el `.gguf` (Q4_K_M) y el adaptador LoRA de respaldo.

QLoRA con Unsloth + TRL: r = 16, 2 épocas, lr = 2e-4, longitud máxima 2048, capas de visión congeladas.

> Lección de Colab: la sesión gratuita se desconectó y agotó la GPU justo después de crear el GGUF, y se perdió. Descarga el adaptador LoRA (celda de guardar LoRA) en cuanto termine el entrenamiento y copia el GGUF a Google Drive antes de descargarlo.

### Plan B · crear el GGUF en el Mac (sin GPU) a partir del adaptador LoRA

Si Colab se desconecta o se agota la GPU gratuita después de entrenar, basta con el adaptador `ministral3-apagon-lora.zip` (celda de guardar LoRA). Necesita Python ≥ 3.10 (el `python3` del sistema es 3.9):

```bash
brew install python@3.12 llama.cpp
$(brew --prefix)/bin/python3.12 -m venv ~/venv-gguf && source ~/venv-gguf/bin/activate
pip install "transformers>=5" peft torch torchvision accelerate safetensors sentencepiece mistral-common
python finetune/merge_lora.py ~/Downloads/ministral3-apagon-lora.zip      # → finetune/build/merged
git clone --depth 1 https://github.com/ggml-org/llama.cpp ~/llama.cpp && pip install ~/llama.cpp/gguf-py
python ~/llama.cpp/convert_hf_to_gguf.py finetune/build/merged --outtype f16 --outfile finetune/build/ministral3-apagon.F16.gguf
llama-quantize finetune/build/ministral3-apagon.F16.gguf finetune/build/ministral3-apagon.Q4_K_M.gguf Q4_K_M
```

Después borra `finetune/build/merged` y el `.F16.gguf` (~14 GB). `finetune/build/` y `*.gguf` están en `.gitignore`.

## 3. Cargar el modelo en Ollama

```bash
ollama show ministral-3:3b --modelfile > finetune/Modelfile
# Edita finetune/Modelfile: cambia la línea FROM SIN «#» (la que apunta a ~/.ollama/models/blobs/…);
# la de «# FROM ministral-3:3b» es un comentario. Si cambias la que no es, Ollama sigue usando el modelo base.
#   FROM ./build/ministral3-apagon.Q4_K_M.gguf      (ruta relativa a finetune/, sin espacios)
ollama create ministral-apagon -f finetune/Modelfile
ollama run ministral-apagon "Hola"
```

Así se reutiliza la plantilla de chat de Ministral 3 que ya funciona en Ollama.

Si Colab no pudo exportar el GGUF: descarga el modelo fusionado (`merged_16bit`) y conviértelo en el Mac con llama.cpp (`convert_hf_to_gguf.py` y después `llama-quantize … Q4_K_M`).

## Resultado del entrenamiento (1–2 nov)

- **Datos:** 470 ejemplos (423 entrenamiento, 47 validación): 290 normales, 116 trampas, 37 sin respuesta, 27 cálculos. Revisión manual de los 546 generados: 76 descartados, con su motivo en `excluidas.tsv` (texto basura de las webs, temas ajenos al apagón, unidades de EE. UU., respuestas que no responden). Una se excluyó por error como «cifra inventada» (insulina de la bomba cada 48 h): sí está en la guía de la FDA; corregido en `excluidas.tsv` cuando el modelo ya estaba entrenado.
- **Tokenizador:** el de Ministral 3 trae un regex incorrecto; el cuaderno lo recarga con `fix_mistral_regex=True` para que coincida con llama.cpp.
- **Entrenamiento:** 106 pasos, 49 min en una T4. Pérdida de validación 0,62 (época 1) → 0,30 (época 2), sin sobreajuste. Ojo: la pérdida incluye el prompt (reglas + guías), no solo la respuesta.
- **Antes/después** (5 preguntas de validación): 87→51, 66→22, 92→48 y 38→15 palabras; desaparecen las negritas y los rellenos inventados. Persisten errores de conocimiento del modelo base (p. ej. «la humedad no hace saltar el diferencial»).
- **Incidencia:** Colab se desconectó y agotó la GPU gratuita tras crear el GGUF; se rehízo en el Mac con el plan B.

## Publicación en Hugging Face (2 nov)

https://huggingface.co/cocoataster/ministral3-apagon-GGUF · `ministral3-apagon.Q4_K_M.gguf` (2,1 GB) y la ficha `finetune/hf/README.md` (qué es, entrenamiento, resultados, limitaciones, Apache 2.0; sin texto de las guías). Se subió a mano desde la web porque este entorno no llega a huggingface.co; `finetune/publicar_hf.sh` hace lo mismo desde la terminal. La app iOS descarga el modelo de ahí (`app/hf_repo.txt`).

## 4. Evaluar (mismas condiciones que la v2)

```bash
python3 eval/run_rag.py ministral-3b-ft   # golden set de desarrollo → results/rag_ministral-3b-ft.csv
python3 eval/judge.py
python3 eval/summary.py
```

Compara `ministral-3b-ft · RAG v2` con `ministral-3b · RAG v2`: correctas, peligrosas, trampas, **tokens/resp.** y **segundos/resp.**

El set de test ya se usó para elegir el modelo. Si se pasa también el modelo con fine-tuning (`python3 eval/run_rag.py ministral-3b-ft --test`), se hace **una sola vez** y se presenta como resultado aparte, sin ajustar nada después de verlo.
