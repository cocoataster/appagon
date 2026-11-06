"""Paso 4 · Evalúa a los finalistas con el asistente completo (reglas + calculadoras + RAG).

Mismo golden set, mismas condiciones para los dos. Requiere haber ejecutado rag/build_index.py.
Uso:
    python3 eval/run_rag.py                      # los dos finalistas
    python3 eval/run_rag.py gemma4-e2b --limit 5 # prueba rápida
    python3 eval/run_rag.py --test               # SET DE TEST (una sola vez, al final) → results/test_*.csv
Después: python3 eval/judge.py  y  python3 eval/summary.py
"""
import os, sys, time
from common import MODELS, GOLDEN, RESULTS, read_csv, write_csv, numeric_ok, chat
from pipeline import answer

FINALISTS = ["gemma4-e2b", "ministral-3b"]

args = sys.argv[1:]
limit = None
if "--limit" in args:
    i = args.index("--limit"); limit = int(args[i + 1]); del args[i:i + 2]
TEST = "--test" in args
if TEST:
    args.remove("--test")
targets = args or FINALISTS
data = os.path.join(os.path.dirname(GOLDEN), "test_set.csv") if TEST else GOLDEN
prefix = "test" if TEST else "rag"
golden = read_csv(data)[:limit]

for alias in targets:
    model = MODELS[alias]
    print(f"\n== {'TEST' if TEST else 'RAG'} · {alias} ({model}) · {len(golden)} preguntas ==")
    try:
        chat(model, "Hola")
    except Exception as e:
        print(f"Aviso en el calentamiento: {e}")
    rows, t0 = [], time.time()
    out = os.path.join(RESULTS, f"{prefix}_{alias}.csv")
    for g in golden:
        try:
            text, m = answer(model, g["pregunta"])
        except Exception as e:
            text, m = f"ERROR: {e}", {"tokens": 0, "tok_s": 0, "segundos": 0, "cortada": "",
                                     "reglas": "", "calculo": "", "fuentes_rag": ""}
        num = numeric_ok(text, g["valor_numerico"]) if g["es_numerica"] == "sí" else ""
        rows.append({
            "id": g["id"], "categoria": g["categoria"], "tipo": g["tipo"],
            "pregunta": g["pregunta"], "respuesta_referencia": g["respuesta_referencia"],
            "valor_numerico": g["valor_numerico"], "respuesta_modelo": text,
            "numerica_ok": num, **m,
        })
        write_csv(out, rows)
        flag = "" if num == "" else (" ✓num" if num else " ✗num")
        extra = (" 🛡" if m.get("reglas") else "") + (" 🧮" if m.get("calculo") else "")
        print(f"{g['id']} {m['tok_s']:>5} tok/s{flag}{extra}  {text[:70]!r}")
    print(f"→ {out}  ({time.time() - t0:.0f} s)")
