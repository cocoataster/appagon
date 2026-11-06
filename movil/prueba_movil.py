"""Paso 6 · Prueba de riesgo: ¿arranca el modelo en el móvil y cuánto tarda la primera palabra?

Genera 3 mensajes de la demo EXACTAMENTE como los recibe el modelo en la app (reglas + cálculo + 6 trozos
de las guías) para pegarlos en PocketPal AI (iPhone y Android), y mide lo mismo en el Mac como referencia.

Uso (en el Mac, con Ollama abierto):
    python3 movil/prueba_movil.py
Salida:
    movil/prompts/sistema.txt        → mensaje de sistema (en PocketPal: crea un «Pal» con este texto)
    movil/prompts/1_nevera.txt …     → un mensaje por pregunta, para copiar y pegar
    movil/mediciones.csv             → cifras del Mac + columnas vacías para iPhone y Android
"""
import csv, json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "eval"))
from common import OLLAMA  # noqa: E402
import pipeline  # noqa: E402

MODEL = "ministral-apagon"
DEMO = [
    ("1_nevera", "Se ha ido la luz hace 3 horas, ¿la comida de la nevera sigue siendo segura?"),
    ("2_agua", "Somos 4 en casa, ¿cuánta agua necesitamos para 3 días?"),
    ("3_radio", "¿Qué emisora de radio sigo durante el apagón y cómo la escucho sin luz?"),
]


def run(system, user):
    body = {"model": MODEL, "stream": False, "think": False,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "options": {"temperature": 0, "seed": 42, "num_ctx": 4096, "num_predict": 256}}
    req = urllib.request.Request(f"{OLLAMA}/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=300))


def unload():
    req = urllib.request.Request(f"{OLLAMA}/api/generate", data=json.dumps({"model": MODEL, "keep_alive": 0}).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=60).read()


def main():
    out = os.path.join(HERE, "prompts"); os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "sistema.txt"), "w", encoding="utf-8").write(pipeline.SYSTEM_RAG)
    rows = []
    for name, q in DEMO:
        user, _ = pipeline.build_prompt(q)
        unload()                       # Ollama guarda en memoria el último mensaje: sin esto, la 1.ª palabra sale casi 0 s
        run("Hola", "Hola")            # carga el modelo (el tiempo de carga no cuenta)
        open(os.path.join(out, name + ".txt"), "w", encoding="utf-8").write(user)
        r = run(pipeline.SYSTEM_RAG, user)
        pe, pd = r.get("prompt_eval_count", 0), r.get("prompt_eval_duration", 0) / 1e9
        ev, ed = r.get("eval_count", 0), r.get("eval_duration", 0) / 1e9
        rows.append({"pregunta": q, "caracteres_mensaje": len(pipeline.SYSTEM_RAG) + len(user),
                     "tokens_entrada": pe, "tokens_respuesta": ev,
                     "mac_1a_palabra_s": round(pd, 2), "mac_tok_s": round(ev / ed, 1) if ed else 0,
                     "mac_total_s": round(pd + ed, 2),
                     "iphone_1a_palabra_s": "", "iphone_tok_s": "", "iphone_ram_gb": "",
                     "android_1a_palabra_s": "", "android_tok_s": "", "android_ram_gb": "",
                     "respuesta_mac": r["message"]["content"].strip()})
        print(f"{name}: {pe} tokens de entrada · 1.ª palabra {pd:.2f} s · {rows[-1]['mac_tok_s']} tok/s\n  → {rows[-1]['respuesta_mac']}\n")
    with open(os.path.join(HERE, "mediciones.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    print("→ movil/prompts/ y movil/mediciones.csv")


if __name__ == "__main__":
    main()
