---
license: apache-2.0
language:
  - es
base_model: mistralai/Ministral-3-3B-Instruct-2512
pipeline_tag: text-generation
tags:
  - gguf
  - llama.cpp
  - offline
  - on-device
  - emergencias
  - rag
---

# Ministral 3 3B · Asistente offline para apagones (GGUF Q4_K_M)

Ministral 3 3B Instruct afinado (QLoRA) para responder **sin conexión, en el móvil**, preguntas de un hogar durante un apagón en España: comida y nevera, agua, energía, comunicación, seguridad, frío y calor, y preparación.

Proyecto final del Programa Técnico Avanzado en Ingeniería de IA (KeepCoding) · Eric Sans · noviembre de 2026.

> **No es un servicio de emergencias ni da consejo médico.** Si hay riesgo para la vida, llama al 112.

## Para qué sirve (y para qué no)

El modelo **no se usa solo**: está entrenado para redactar la respuesta a partir de lo que le da la app, que en el móvil hace lo siguiente:

1. **Reglas de seguridad fijas** en código (generador, monóxido, gas, medicamentos, lejía, radio…).
2. **Calculadoras deterministas** (horas de nevera y congelador, litros de agua, cargas de una power bank).
3. **Búsqueda en guías oficiales** (RAG local con EmbeddingGemma, 431 trozos, las españolas primero).

El fine-tuning enseña el **estilo**, no los datos: texto plano en 1–3 frases, copiar el dato calculado, negarse y derivar en preguntas peligrosas, y decir «las guías no responden» sin inventar. Sin ese contexto el modelo responde como el Ministral original, con sus errores.

## Formato del mensaje

```
<s>[SYSTEM_PROMPT]{instrucciones}[/SYSTEM_PROMPT][INST]REGLAS DE SEGURIDAD: …
DATOS CALCULADOS: …
GUÍAS: [1] (fuente · España) texto…
PREGUNTA: …[/INST]
```

Temperatura 0. Las instrucciones y el código completo (Python y app iOS) están en el repositorio del proyecto.

## Entrenamiento

- Base: `unsloth/Ministral-3-3B-Instruct-2512` (Mistral AI, Apache 2.0), parte de visión congelada.
- QLoRA con Unsloth + TRL en una GPU T4 (Colab): r = 16, 2 épocas, lr 2e-4, longitud máxima 2048, 106 pasos (49 min). Tokenizador corregido (`fix_mistral_regex=True`).
- Datos: **470 ejemplos sintéticos** (423 de entrenamiento, 47 de validación: 290 normales, 116 trampas, 37 sin respuesta, 27 cálculos). Preguntas y respuestas generadas por Muse Glimmer 30B con el mismo contexto que recibe la app. Revisión manual de los 546 generados: 76 descartados. Ninguna pregunta se parece a las de los sets de evaluación (similitud < 0,88).
- Pérdida de validación: 0,62 → 0,30.
- Fusionado en 16 bits y cuantizado a Q4_K_M con llama.cpp (2,1 GB, solo texto).

## Evaluación (asistente completo, juez Muse Glimmer 30B)

| | Ministral 3 3B sin afinar | **Este modelo** |
|---|---|---|
| Correctas + parciales (94 preguntas de desarrollo) | 85 % | **87 %** |
| Respuestas peligrosas (de 94) | 5 | **3** (revisadas a mano: 1 clara y 1 discutible) |
| Cifras correctas | 84 % | **88 %** |
| Preguntas trampa seguras | 10/10 | 10/10 |
| Tokens por respuesta | 97 | **47** |
| Set de test (56 preguntas nuevas): correctas + parciales / peligrosas / trampas | 91 % / 3 / 18 de 20 | **93 % / 1 / 19 de 20** |

En un iPhone 16 (llama.cpp, GPU): lee el contexto a ~200 tokens/s (primera palabra en 7–9 s con ~1.500 tokens de guías) y escribe a 10–21 tokens/s, con un pico de 3 GB de memoria.

## Limitaciones conocidas

- Al acortar, a veces omite un detalle de la referencia (respuestas «parciales»).
- Tendía a negarse a dar cantidades (lejía para el agua) o emisoras; en la app se resuelve con reglas fijas.
- Puede copiar mal una cifra del cálculo según el hardware; la app comprueba la cifra y muestra el dato correcto si no coincide.
- Respuestas revisadas con fallos: hipotermia (no dice que llamen al 112), kit de apagón (incluye «estufa autónoma»), «mi familia no contesta» (dice «llama al 112»).
- Solo español de España y solo apagones.

## Licencia

Apache 2.0, como el modelo base. Las guías oficiales usadas en el RAG son de sus autores y no se incluyen aquí.
