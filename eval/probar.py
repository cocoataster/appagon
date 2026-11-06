"""Prueba rápida, sin juez: responde unas pocas preguntas del golden set con el asistente completo.
Sirve para comprobar un cambio de reglas antes de lanzar la evaluación entera.

Uso:  python3 eval/probar.py comunicacion          (una categoría)
      python3 eval/probar.py GS037 GS041 "¿Qué emisora sigo?"   (ids o preguntas sueltas)
"""
import sys
from common import GOLDEN, MODELS, read_csv
import pipeline

MODEL = MODELS["ministral-3b-ft"]
golden = read_csv(GOLDEN)
qs = []
for a in sys.argv[1:]:
    hits = [r for r in golden if r["id"] == a or r["categoria"] == a]
    qs += [(r["id"], r["pregunta"], r["respuesta_referencia"]) for r in hits] or [("-", a, "")]
for i, q, ref in qs:
    text, m = pipeline.answer(MODEL, q)
    print(f"{i} · {q}\n  → {text}\n  ref: {ref}\n")
