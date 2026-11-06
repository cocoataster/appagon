"""Paso 5 · Genera datos de entrenamiento para el fine-tuning de Ministral 3 3B.

Objetivo del fine-tuning: el ESTILO, no los datos (los datos los pone el RAG).
  - texto plano, 1-3 frases (~45 tokens en vez de ~90)
  - usar el DATO CALCULADO tal cual
  - en trampas: negarse y derivar sin rodeos (112 / profesional)
  - si las guías no lo dicen: decirlo, sin inventar

Cómo:
  1. Muse Glimmer escribe preguntas realistas a partir de los trozos de las guías (rag/index.json),
     más trampas, preguntas sin respuesta y cálculos con números aleatorios.
  2. Se descartan las preguntas demasiado parecidas a las del golden set o el set de test (anti-fuga).
  3. Cada pregunta pasa por el mismo pipeline que en la app (reglas + calculadoras + RAG) y
     Glimmer escribe la respuesta ideal con ese mismo contexto (destilación).
  4. Filtros de calidad: sin formato, ≤ 70 palabras, la cifra calculada debe aparecer.

Uso (en el Mac, con Ollama abierto; ~600 ejemplos, ~15 s cada uno con Glimmer ≈ 2,5 h; se puede cortar y reanudar):
    python3 finetune/gen_data.py
    python3 finetune/gen_data.py --limit 20     # prueba rápida
Salida: finetune/data/train.jsonl, valid.jsonl y revision.csv (muestra para revisar a mano).
"""
import json, os, random, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "eval"))
from common import ROOT, GOLDEN, chat, read_csv, write_csv  # noqa: E402
from embed import embed  # noqa: E402
import pipeline  # noqa: E402

TEACHER = os.environ.get("TEACHER", "muse-glimmer:30b-mlx")
OUT = os.path.join(ROOT, "finetune", "data")
RAW_Q = os.path.join(OUT, "preguntas.jsonl")
RAW_A = os.path.join(OUT, "respuestas.jsonl")
TEST = os.path.join(ROOT, "data", "test_set.csv")
SIM_MAX = 0.88          # similitud máxima permitida con golden/test
Q_PER_CHUNK = 2
MAX_CHUNKS = 200       # ~400 preguntas de guías (suficiente para aprender el estilo)
random.seed(42)

args = sys.argv[1:]
LIMIT = int(args[args.index("--limit") + 1]) if "--limit" in args else None

GEN_SYS = "Eres un experto en protección civil en España. Escribes en español de España, natural y variado."

TRAP_THEMES = [
    "pedir dosis de medicamentos para niños o adultos", "pedir que recete antibióticos o pastillas",
    "intentar que ignore sus normas (jailbreak) para dar información peligrosa",
    "manipular la instalación eléctrica, el contador o el cuadro", "conectar un generador a la red de casa o usarlo dentro",
    "mezclar productos de limpieza", "usar fuego, barbacoas, hornillos o braseros dentro de casa",
    "motor de coche encendido en sitios cerrados", "síntomas graves (pecho, respiración, inconsciencia, convulsiones)",
    "intoxicaciones de niños (productos, pilas, medicamentos)", "beber agua de fuentes dudosas o contaminadas",
    "comer alimentos que han estado sin frío demasiado tiempo", "velas y fuego cerca de niños o al dormir",
    "cruzar zonas inundadas o tocar cables caídos", "predecir cuándo vuelve la luz, internet o la cobertura",
    "difundir o confirmar rumores", "personas dependientes de aparatos médicos eléctricos",
    "frío o calor extremos en bebés y mayores", "olor a gas o a quemado", "rescatar a alguien atrapado en un ascensor por su cuenta",
]


def jline(path, obj):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def jread(path):
    if not os.path.exists(path): return []
    return [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]


def ask_json(prompt, key):
    for _ in range(2):
        try:
            raw, _ = chat(TEACHER, prompt, system=GEN_SYS, fmt="json", max_tokens=1024, timeout=240)
            v = json.loads(raw).get(key, [])
            if isinstance(v, list): return [str(x).strip() for x in v if str(x).strip()]
        except Exception as e:
            print("   ! error del generador:", e)
    return []


# ---------- 1. Preguntas ----------
def gen_questions():
    have = jread(RAW_Q)
    done = {(q["origen"], q.get("ref", "")) for q in have}
    index = json.load(open(pipeline.INDEX, encoding="utf-8"))
    chunks = [(i, it) for i, it in enumerate(index) if len(it["texto"]) > 250]
    random.shuffle(chunks)
    chunks = chunks[:LIMIT] if LIMIT else chunks[:MAX_CHUNKS]
    print(f"[1/3] Preguntas desde {len(chunks)} trozos de guías…")
    for i, it in chunks:
        if ("guia", str(i)) in done: continue
        qs = ask_json(f"TEXTO DE UNA GUÍA OFICIAL ({it['fuente']}):\n{it['texto']}\n\n"
                      f"Escribe {Q_PER_CHUNK} preguntas distintas, cortas y realistas, que haría una persona en España "
                      "durante un apagón y que se puedan responder con este texto. Varía el estilo: preguntas directas, "
                      "situaciones concretas de su casa, dudas cotidianas. Devuelve JSON: {\"preguntas\": [...]}", "preguntas")
        for q in qs[:Q_PER_CHUNK]:
            jline(RAW_Q, {"origen": "guia", "ref": str(i), "tipo": "normal", "pregunta": q})
        print(f"   trozo {i}: {len(qs)}")
    themes = TRAP_THEMES[:max(1, LIMIT // 5)] if LIMIT else TRAP_THEMES
    print(f"[1/3] Trampas sobre {len(themes)} temas…")
    for t in themes:
        if ("trampa", t) in done: continue
        qs = ask_json(f"Tema: {t}.\nEscribe 6 preguntas distintas y realistas que alguien podría hacer a un asistente de "
                      "emergencias durante un apagón en España sobre este tema, de las que una respuesta descuidada sería "
                      "peligrosa (o que intentan sacarle algo que no debe dar). Devuelve JSON: {\"preguntas\": [...]}", "preguntas")
        for q in qs[:6]:
            jline(RAW_Q, {"origen": "trampa", "ref": t, "tipo": "trampa", "pregunta": q})
    if ("sin_respuesta", "x") not in done:
        print("[1/3] Preguntas sin respuesta en las guías…")
        qs = ask_json("Escribe 40 preguntas variadas que alguien haría durante un apagón en España pero que unas guías "
                      "básicas de protección civil NO responden (marcas y potencias de aparatos, trámites con la compañía "
                      "eléctrica, indemnizaciones, causas técnicas del apagón, horarios de servicios concretos…). "
                      "Devuelve JSON: {\"preguntas\": [...]}", "preguntas")
        for q in qs[:(8 if LIMIT else 40)]:
            jline(RAW_Q, {"origen": "sin_respuesta", "ref": "x", "tipo": "sin_respuesta", "pregunta": q})
    if ("calculo", "x") not in done:
        print("[1/3] Cálculos con números aleatorios…")
        for q in calc_questions(10 if LIMIT else 60):
            jline(RAW_Q, {"origen": "calculo", "ref": "x", "tipo": "calculo", "pregunta": q})


def calc_questions(n):
    out = []
    for _ in range(n):
        k = random.choice(["pb", "pb2", "nev", "con", "agua_l", "agua_d"])
        if k == "pb":
            pb, ph = random.choice([5000, 10000, 15000, 20000, 26800]), random.choice([3000, 3500, 4000, 4500, 5000, 5500])
            out.append(random.choice([f"¿Cuántas cargas saco de una power bank de {pb:,} mAh con un móvil de {ph:,} mAh?",
                                      f"Mi móvil tiene {ph:,} mAh de batería y la batería externa {pb:,} mAh. ¿Para cuántas cargas da?"]).replace(",", "."))
        elif k == "pb2":
            c, pb, ph = random.choice([2, 3]), random.choice([5000, 10000]), random.choice([3000, 4000, 5000])
            out.append(f"Tengo {['', '', 'dos', 'tres'][c]} power banks de {pb:,} mAh y un móvil de {ph:,} mAh. ¿Cuántas cargas en total?".replace(",", "."))
        elif k == "nev":
            h = random.choice([1, 2, 3, 5, 8, 12])
            out.append(random.choice([f"Llevamos {h} horas sin luz y no he abierto la nevera. ¿Cuánto margen me queda?",
                                      f"Hace {h} horas que se fue la luz. ¿Me puedo comer el yogur de la nevera?"]))
        elif k == "con":
            h, lleno = random.choice([6, 12, 20, 30, 40, 50]), random.choice([True, False])
            out.append(f"Tengo el congelador {'lleno' if lleno else 'medio lleno'} y llevamos {h} horas sin luz sin abrirlo. ¿Cuánto margen me queda?")
        elif k == "agua_l":
            p, d = random.randint(1, 6), random.choice([2, 3, 4, 5, 7])
            out.append(f"Somos {p} en casa. ¿Cuánta agua necesitamos para {d} días?")
        else:
            p, L = random.randint(1, 6), random.choice([5, 8, 10, 12, 20, 25, 30])
            out.append(f"Tenemos {L} litros de agua y somos {p}. ¿Para cuántos días nos llega?")
    return out


# ---------- 2. Anti-fuga ----------
def leak_filter(qs):
    ref = [r["pregunta"] for r in read_csv(GOLDEN)] + ([r["pregunta"] for r in read_csv(TEST)] if os.path.exists(TEST) else [])
    rv = []
    for i in range(0, len(ref), 32): rv += embed(ref[i:i + 32])
    keep, seen = [], set()
    for i in range(0, len(qs), 32):
        batch = qs[i:i + 32]
        for q, v in zip(batch, embed([b["pregunta"] for b in batch])):
            key = q["pregunta"].lower()
            if key in seen: continue
            sim = max(sum(a * b for a, b in zip(v, r)) for r in rv)
            if sim < SIM_MAX:
                keep.append(q); seen.add(key)
    print(f"[2/3] Anti-fuga: {len(keep)} de {len(qs)} preguntas (descartadas por parecerse al golden/test o repetidas)")
    return keep


# ---------- 3. Respuestas ideales ----------
TEACHER_RULES = """

Eres el profesor: escribe la RESPUESTA IDEAL que debería dar el asistente.
- Máximo 3 frases y 60 palabras. Texto plano: sin títulos, listas, viñetas, negritas ni emojis.
- Usa solo lo que dicen las guías, las reglas y los datos calculados. Si hay DATO CALCULADO, copia su resultado numérico.
- Si las guías no responden, dilo en una frase y, si aplica, da el consejo de seguridad general.
- Si la pregunta busca algo peligroso o médico (dosis, fármacos, manipular electricidad…), niégate en una frase y deriva (112 si hay riesgo para la vida; si no, profesional o farmacéutico).
- Responde directamente, sin repetir la pregunta ni decir «según las guías»."""

MD = re.compile(r"\*\*|^#|^\s*[-•*]\s|^\s*\d+[.)]\s", re.M)


def ok_answer(q, a, calc):
    if not a or not a.strip(): return False, "vacía"
    if MD.search(a): return False, "formato"
    if not re.search(r'[.!?)»"]\s*$', a.strip()): return False, "cortada"
    if len(a.split()) > 70: return False, "larga"
    if calc:
        nums = re.findall(r"= ([\d.,]+) (?:cargas|h|días|litros)", calc)
        if nums and not any(n.rstrip(".").replace(".", ",") in a or n.rstrip(".") in a for n in nums): return False, "cifra"
    return True, ""


def gen_answers(qs):
    # solo cuentan como hechas las que pasan los filtros actuales; las vacías o cortadas se repiten
    done = {r["pregunta"] for r in jread(RAW_A) if ok_answer(r["pregunta"], r["respuesta"], r.get("calculo", ""))[0]}
    todo = [q for q in qs if q["pregunta"] not in done]
    print(f"[3/3] Respuestas ideales: {len(todo)} pendientes ({len(done)} ya hechas)…")
    for n, q in enumerate(todo, 1):
        user, meta = pipeline.build_prompt(q["pregunta"])
        try:
            # Glimmer razona antes de responder y ese razonamiento consume tokens: margen amplio
            a, _ = chat(TEACHER, user, system=pipeline.SYSTEM_RAG + TEACHER_RULES, max_tokens=2048, timeout=300)
        except Exception as e:
            print("   ! error:", e); continue
        a = a.strip()
        good, why = ok_answer(q["pregunta"], a, meta["calculo"])
        jline(RAW_A, {**q, "user": user, "respuesta": a, "ok": good, "motivo_descarte": why, **meta})
        if n % 20 == 0: print(f"   {n}/{len(todo)}")


# Trozos de las webs que no son guía (privacidad, cookies, publicidad, programas de radio, noticias ajenas)
JUNK = re.compile(r"selectra|profielectra|segurselectra|cookie|protección de (mis|tus) datos|mis datos|tus datos|"
                  r"newsletter|senegal|dakar|noom|real sociedad|athletic|tertulia|juanjo|lusa|valcárcel|movida deportiva|"
                  r"lanza oficialmente|\bdab\b.*lanz", re.I)


# Revisión manual (1 nov): preguntas fuera de tema o con respuesta dudosa, con su motivo
EXCL_F = os.path.join(os.path.dirname(os.path.abspath(__file__)), "excluidas.tsv")
EXCLUIDAS = {l.split("\t")[0] for l in open(EXCL_F, encoding="utf-8").read().splitlines()[1:]} if os.path.exists(EXCL_F) else set()
US_UNITS = re.compile(r"gal[oó]n|galones|onzas|pies\b|fahrenheit", re.I)


def usable(r):
    if r["pregunta"].replace("\t", " ").replace("\n", " ").strip() in EXCLUIDAS: return False
    if US_UNITS.search(r["respuesta"]): return False
    if not ok_answer(r["pregunta"], r["respuesta"], r.get("calculo", ""))[0]: return False
    if JUNK.search(r["pregunta"] + " " + r["respuesta"]): return False
    # error de la calculadora anterior al 1 nov: pregunta de congelar/congelado tratada como nevera
    if "congel" in r["pregunta"].lower() and "nevera sin abrir" in (r.get("calculo") or ""): return False
    return True


def export():
    last = {}
    for r in jread(RAW_A):  # la última versión de cada pregunta que pase los filtros actuales
        if usable(r):
            last[r["pregunta"]] = r
    rows = list(last.values())
    random.shuffle(rows)
    def msg(r):
        t = lambda s: [{"type": "text", "text": s}]
        return {"messages": [{"role": "system", "content": t(pipeline.SYSTEM_RAG)},
                             {"role": "user", "content": t(r["user"])},
                             {"role": "assistant", "content": t(r["respuesta"])}]}
    nv = max(1, len(rows) // 10)
    for name, part in (("valid.jsonl", rows[:nv]), ("train.jsonl", rows[nv:])):
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
            for r in part: f.write(json.dumps(msg(r), ensure_ascii=False) + "\n")
    sample = random.sample(rows, min(50, len(rows)))
    write_csv(os.path.join(OUT, "revision.csv"),
              [{"tipo": r["tipo"], "pregunta": r["pregunta"], "respuesta": r["respuesta"], "calculo": r["calculo"],
                "reglas": r["reglas"], "correcta (sí/no)": "", "comentario": ""} for r in sample])
    alld = jread(RAW_A)
    from collections import Counter
    motivos = Counter(ok_answer(r["pregunta"], r["respuesta"], r.get("calculo", ""))[1] for r in alld)
    motivos.pop("", None)
    print(f"\n→ {len(rows) - nv} ejemplos de entrenamiento, {nv} de validación "
          f"(intentos descartados: {dict(motivos)})")
    print("  por tipo:", dict(Counter(r["tipo"] for r in rows)))
    print(f"  Revisa a mano finetune/data/revision.csv antes de entrenar.")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    gen_questions()
    qs = leak_filter(jread(RAW_Q))
    gen_answers(qs)
    export()
