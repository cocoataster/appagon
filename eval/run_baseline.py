"""Paso 3 · Línea base: pasa el golden set por cada modelo (sin RAG) y guarda las respuestas.

Uso:
    python3 eval/run_baseline.py                 # los 3 modelos
    python3 eval/run_baseline.py gemma4-e2b      # solo uno
    python3 eval/run_baseline.py --limit 5       # prueba rápida con 5 preguntas
    python3 eval/run_baseline.py salamandra-2b qwen3.5-2b   # varios concretos
"""
import os, sys, time
from common import MODELS, GOLDEN, RESULTS, chat, read_csv, write_csv, numeric_ok

args = sys.argv[1:]
limit = None
if "--limit" in args:
    i = args.index("--limit"); limit = int(args[i + 1]); del args[i:i + 2]
targets = args or list(MODELS)

golden = read_csv(GOLDEN)[:limit]

for alias in targets:
    model = MODELS[alias]
    print(f"\n== {alias} ({model}) · {len(golden)} preguntas ==")
    try:
        chat(model, "Hola")  # calentamiento: carga el modelo en memoria
    except Exception as e:
        print(f"Aviso en el calentamiento: {e}")
    rows, t0 = [], time.time()
    out = os.path.join(RESULTS, f"baseline_{alias}.csv")
    for g in golden:
        try:
            text, m = chat(model, g["pregunta"])
        except Exception as e:  # timeout u otro error: se apunta y se sigue
            text, m = f"ERROR: {e}", {"tokens": 0, "tok_s": 0, "segundos": 0, "cortada": ""}
        num = numeric_ok(text, g["valor_numerico"]) if g["es_numerica"] == "sí" else ""
        rows.append({
            "id": g["id"], "categoria": g["categoria"], "tipo": g["tipo"],
            "pregunta": g["pregunta"], "respuesta_referencia": g["respuesta_referencia"],
            "valor_numerico": g["valor_numerico"], "respuesta_modelo": text,
            "numerica_ok": num, **m,
        })
        write_csv(out, rows)  # guarda tras cada pregunta: si se corta, no se pierde nada
        flag = "" if num == "" else (" ✓num" if num else " ✗num")
        cut = " ✂" if m.get("cortada") is True else ""
        print(f"{g['id']} {m['tok_s']:>5} tok/s{flag}{cut}  {text[:70]!r}")
    print(f"→ {out}  ({time.time() - t0:.0f} s)")
