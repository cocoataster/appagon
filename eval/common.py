"""Utilidades compartidas: llamada a Ollama, prompt del sistema y lectura de CSV.
Solo usa la librería estándar de Python (no hace falta pip install)."""
import csv, json, os, re, urllib.request

OLLAMA = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLDEN = os.path.join(ROOT, "data", "golden_set_final.csv")
RESULTS = os.path.join(ROOT, "results")

# Modelos de la línea base (alias corto -> etiqueta de Ollama)
MODELS = {
    "gemma4-e2b": "gemma4:e2b",
    "salamandra-2b": "hf.co/RichardErkhov/BSC-LT_-_salamandra-2b-instruct-gguf:Q4_K_M",
    "qwen3.5-2b": "qwen3.5:2b",
    "ministral-3b": "ministral-3:3b",  # extra: ~3B, Apache 2.0, europeo
    "ministral-3b-ft": "ministral-apagon",  # Paso 5: Ministral con fine-tuning (ver finetune/README.md)
}

SYSTEM_PROMPT = """Eres un asistente de emergencias que funciona sin conexión durante un apagón en España.
Responde siempre en español, en 1 a 3 frases, claras y prácticas.
- Si la pregunta pide una cifra (horas, litros, cargas, minutos), da un número concreto.
- No diagnostiques, no recomiendes medicamentos ni dosis.
- Llama al 112 solo si hay riesgo inmediato para la vida (no por dudas): en un apagón las líneas se saturan.
- Si no lo sabes, dilo; no inventes."""


def chat(model, user, system=SYSTEM_PROMPT, fmt=None, timeout=120, max_tokens=256):
    """Una llamada a /api/chat sin streaming. Devuelve (texto, métricas)."""
    body = {
        "model": model,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "stream": False,
        "think": False,  # sin modo razonamiento: queremos lo que haría el móvil
        "options": {"temperature": 0, "seed": 42, "num_ctx": 4096,
                    "num_predict": max_tokens},  # tope: evita que un modelo se quede generando sin fin
    }
    if fmt:
        body["format"] = fmt
    req = urllib.request.Request(f"{OLLAMA}/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        r = json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.HTTPError as e:
        # Algunos modelos no aceptan "think": reintenta sin él
        if e.code == 400 and "think" in body:
            body.pop("think")
            req = urllib.request.Request(f"{OLLAMA}/api/chat", data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=timeout))
        else:
            raise
    text = r["message"]["content"].strip()
    ev, dur = r.get("eval_count", 0), r.get("eval_duration", 0)
    m = {
        "tokens": ev,
        "tok_s": round(ev / (dur / 1e9), 1) if dur else 0,
        "segundos": round(r.get("total_duration", 0) / 1e9, 2),
        "cortada": r.get("done_reason") == "length",  # True si llegó al tope de tokens
    }
    return text, m


def read_csv(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_csv(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)


NUM = re.compile(r"\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:[.,]\d+)?")

def numbers_in(text):
    """Extrae números en formato español o inglés: '1,7' '10.000' '48' '2.8'."""
    out = []
    for tok in NUM.findall(text):
        t = tok
        if re.fullmatch(r"\d{1,3}(\.\d{3})+(,\d+)?", t):      # 10.000 / 10.000,5
            t = t.replace(".", "").replace(",", ".")
        else:
            t = t.replace(",", ".")
        try:
            out.append(float(t))
        except ValueError:
            pass
    return out


def numeric_ok(answer, expected, tol=0.15):
    """¿Aparece en la respuesta un número dentro de ±15 % del valor esperado?"""
    try:
        exp = float(str(expected).replace(",", "."))
    except ValueError:
        return None
    if exp == 112:
        return "112" in answer
    return any(abs(n - exp) <= max(tol * abs(exp), 0.05) for n in numbers_in(answer))
