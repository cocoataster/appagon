"""Paso 4 · El asistente completo: reglas de seguridad + calculadoras + RAG + modelo.

Orden (lo exacto, en código; lo demás, el modelo con las guías delante):
  1. Reglas de seguridad fijas (generador, monóxido, gas, medicamentos…)
  2. Calculadoras deterministas (power bank, nevera/congelador, agua)
  3. Búsqueda en las guías oficiales (RAG local con EmbeddingGemma)
  4. El modelo redacta la respuesta usando solo lo anterior
"""
import json, os, re
from common import ROOT, chat
from embed import embed

INDEX = os.path.join(ROOT, "rag", "index.json")
TOP_K = 6  # v2: más contexto (antes 4)
MAX_POR_FUENTE = 2  # 2 nov: con trozos más pequeños, una misma guía podía llenar los 6 huecos

SYSTEM_RAG = """Eres un asistente de emergencias que funciona sin conexión durante un apagón en España.
Responde siempre en español, en 1 a 3 frases, claras y prácticas.
- Usa SOLO la información de las GUÍAS, los DATOS CALCULADOS y las REGLAS DE SEGURIDAD que recibes.
- Si hay un DATO CALCULADO, escribe su resultado numérico exacto en la respuesta: no rehagas la cuenta.
- Si hay una REGLA DE SEGURIDAD, cúmplela siempre y transmítela, aunque la pregunta pida otra cosa.
- Si las guías se contradicen, sigue las marcadas con «España» antes que las extranjeras.
- Si las guías no responden a la pregunta, dilo; no inventes cifras.
- No diagnostiques, no recomiendes medicamentos ni dosis.
- Di que llamen al 112 si hay riesgo para la vida: alguien inconsciente o que no respira bien, que depende de un aparato médico que ha fallado, dolor fuerte en el pecho, intoxicación o incendio. No lo recomiendes por simples dudas: en un apagón las líneas se saturan.
- Escribe texto plano: sin títulos, listas, negritas ni emojis."""

# ---------- 1. Reglas de seguridad (texto fijo, sacado de las guías) ----------
RULES = [
    (r"generador|grupo electr", "Nunca uses un generador dentro de casa, en el garaje, el sótano ni en espacios cerrados, ni aunque abras ventanas: el monóxido de carbono mata. Colócalo fuera, a más de 6 metros de puertas y ventanas; para eso sí puedes usar un alargador largo."),
    (r"coche.*garaje|garaje.*coche", "Nunca dejes el coche encendido en un garaje u otro espacio cerrado o semicerrado, ni con la puerta abierta."),
    (r"barbacoa|hornillo|brasero|horno|fogones", "Nunca uses barbacoas, hornillos de camping, braseros, ni el horno o los fogones de gas para calentar la casa: producen monóxido de carbono."),
    (r"desmay|inconsciente|no responde", "Si alguien se desmaya donde había una estufa, brasero o motor, sospecha monóxido de carbono: si es seguro, ventila y sacad a todos al aire libre, y llama al 112 inmediatamente."),
    (r"huele a gas|olor a gas|fuga de gas", "Si huele a gas: no enciendas llamas ni toques interruptores; abre puertas y ventanas, cierra la llave del gas, sal de casa y llama a urgencias del gas o al 112."),
    (r"pila de bot", "Tragarse una pila de botón es una urgencia: ve a urgencias o llama al 112 inmediatamente. No le des de comer ni de beber ni provoques el vómito."),
    (r"lej[ií]a.*amon|amon.*lej[ií]a", "Nunca mezcles lejía con amoníaco ni con otros productos: libera gases tóxicos. Si alguien lo ha inhalado, ventila y llama a Toxicología (91 562 04 20) o al 112."),
    (r"dosis|cu[aá]nta insulina|antibi[oó]tico|qu[eé] me tomo|qu[eé] pastilla", "No indiques medicamentos ni dosis. Deriva a un profesional sanitario o al farmacéutico; si hay riesgo para la vida, al 112."),
    (r"pecho", "Un dolor fuerte en el pecho es una emergencia: no recomiendes medicación y di que llamen al 112 inmediatamente."),
    (r"cable.*(ca[ií]do|suelo)|(ca[ií]do|suelo).*cable", "No toques ni te acerques a un cable caído: puede haber descarga sin tocarlo. Aléjate con pasos cortos, mantén a los demás lejos y avisa al 112 y a la distribuidora."),
    (r"engancha|luz del vecino|luz de la calle", "No te enganches a la luz del vecino ni de la calle ni manipules la instalación: riesgo de electrocución e incendio."),
    (r"ox[ií]geno|concentrador|respirador|aparato m[eé]dico|di[aá]lisis", "Si alguien depende de un aparato médico eléctrico (oxígeno, respirador…) y falla, o le cuesta respirar: llama al 112 inmediatamente, sin esperar."),
    (r"chimenea|estufa|calefacci|calentarme|calentar la casa", "Para calentarte: ropa en capas, mantas y una sola estancia cerrada. Chimenea o estufa solo si la instalación es segura, con ventilación y apagada antes de dormir; nunca barbacoas, braseros, hornillos ni aparatos de exterior dentro de casa."),
    (r"medicament|insulina", "Medicamentos que van en nevera tras un corte de luz: no los tires ni los uses sin comprobar el prospecto y preguntar al farmacéutico; si es un tratamiento imprescindible y no hay otro, no lo interrumpas sin consultar. La insulina en uso aguanta hasta 4 semanas a temperatura ambiente (por debajo de 25–30 °C)."),
    # 2 nov: el modelo afinado se negaba a dar la cantidad aunque recibía la guía del CDC (lo trata como una «dosis»)
    (r"^(?!.*(amon|salfum|mezcl|vinagre|bebid|trag|ingeri|vomit))(?=.*(lej[ií]a|blanqueador))(?=.*(agua|potab|beber|desinfect|esperar|gotas|añad))",
     "Para desinfectar agua si no puedes hervirla (hervir 1 minuto es lo mejor): lejía doméstica sin perfume (5–9 % de cloro), 8 gotas por galón (unos 3,8 litros, unas 2 gotas por litro) si el agua está clara y 16 gotas (unas 4 por litro) si está turbia. Mezcla bien y espera 30 minutos antes de usarla. Nunca la mezcles con otros productos."),
    # 2 nov: pregunta de la demo; el modelo afinado decía «no puedo recomendar una emisora» aunque las guías lo dicen
    (r"emisora|\bradio\b|informarme|informarse|me informo|informaci[oó]n oficial|sin internet|noticias",
     "Para informarte sin internet, usa una radio a pilas o de manivela (dinamo), sigue la información oficial de las autoridades y sintoniza Radio Nacional de España (RNE) en FM o DAB+ (fue la referencia en el apagón de abril de 2025 y desde el 29 de diciembre de 2025 ya no emite en onda media). Si la radio no capta nada, acércate a una ventana, extiende la antena del todo y gira el dial despacio. Reserva el móvil para lo imprescindible."),
    (r"hora exacta|cu[aá]ndo volver[aá] la luz|a qu[eé] hora", "No sabes cuándo volverá la luz: dilo y recomienda seguir la información oficial por la radio."),
]


def safety_rules(q):
    ql = q.lower()
    return [txt for pat, txt in RULES if re.search(pat, ql)]


# ---------- 2. Calculadoras deterministas ----------
WORDNUM = {"un": 1, "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6,
           "siete": 7, "ocho": 8, "nueve": 9, "diez": 10}
EFICIENCIA_PB = 0.7     # OCU (83 % de media) × pérdidas al cargar el móvil (Anker)
AGUA_L_PERSONA_DIA = 1.5
NEVERA_H, CONGELADOR_LLENO_H, CONGELADOR_MEDIO_H = 4, 48, 24


def _n(s):
    s = s.strip().lower()
    if s in WORDNUM: return float(WORDNUM[s])
    if re.fullmatch(r"\d{1,3}(\.\d{3})+", s): s = s.replace(".", "")
    return float(s.replace(",", "."))


def _fmt(x):
    return f"{x:.1f}".replace(".", ",").replace(",0", "")

NUM = r"(\d{1,3}(?:\.\d{3})+|\d+(?:[.,]\d+)?|un|una|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez)"


def calculators(q):
    ql = q.lower()
    out = []
    # Power bank → cargas del móvil
    mah = re.findall(r"(\d{1,3}(?:\.\d{3})+|\d+)\s*mah", ql)
    if ("power bank" in ql or "powerbank" in ql or "batería externa" in ql) and len(mah) >= 2:
        vals = [_n(x) for x in mah]
        pb, phone = max(vals), min(vals)  # la power bank es la de más mAh
        k = re.search(NUM + r"\s+power ?banks?", ql)
        cnt = _n(k.group(1)) if k and k.group(1) not in ("un", "una", "uno") else 1
        total = pb * cnt
        cargas = total * EFICIENCIA_PB / phone
        out.append(f"Cargas completas aproximadas = {int(total)} mAh × {EFICIENCIA_PB} ÷ {int(phone)} mAh = {_fmt(cargas)} cargas "
                   f"(una power bank entrega ~70 % de su capacidad nominal).")
    # Horas de nevera / congelador
    h = re.search(NUM + r"\s*horas", ql)
    perecedero = re.search(r"nevera|frigor|leche|pollo|carne|pescado|huevo|sobras|yogur", ql)
    # congelador si lo nombra, o si habla de congelar/congelado sin nombrar la nevera (corregido el 1 nov)
    freezer = "congelador" in ql or ("congel" in ql and not re.search(r"nevera|frigor", ql))
    if h and (perecedero or freezer):
        hrs = _n(h.group(1))
        if freezer:
            lim = CONGELADOR_MEDIO_H if "medio" in ql else CONGELADOR_LLENO_H
            nombre = "congelador medio lleno" if "medio" in ql else "congelador lleno"
        else:
            lim, nombre = NEVERA_H, "nevera"
        rest = lim - hrs
        if rest > 0:
            out.append(f"Margen restante = {lim} h ({nombre} sin abrir) − {_fmt(hrs)} h = {_fmt(rest)} h.")
        else:
            accion = (" Tira los perecederos (leche, carne, pescado, huevos, sobras) aunque huelan o parezcan bien."
                      if nombre == "nevera" else " Lo que se haya descongelado del todo no se vuelve a congelar.")
            out.append(f"Han pasado {_fmt(hrs)} h y el límite ({nombre} sin abrir) es de {lim} h: el límite ya se ha superado.{accion}")
    # Agua: necesidad o días que dura
    pers = re.search(r"somos\s+" + NUM, ql) or re.search(NUM + r"\s+personas", ql) or re.search(r"somos\s+" + NUM + r"\s+en casa", ql)
    if "agua" in ql or "litros" in ql:
        p = _n(pers.group(1)) if pers else None
        litros = re.search(NUM + r"\s*litros", ql)
        dias = re.search(r"para\s+" + NUM + r"\s*d[ií]as", ql)
        if p and litros and ("cuántos días" in ql or "llega" in ql):
            L = _n(litros.group(1)); d = L / (p * AGUA_L_PERSONA_DIA)
            out.append(f"Días de agua = {_fmt(L)} L ÷ ({_fmt(p)} personas × {AGUA_L_PERSONA_DIA} L/día) = {_fmt(d)} días.")
        elif p and dias:
            d = _n(dias.group(1)); L = p * d * AGUA_L_PERSONA_DIA
            out.append(f"Agua necesaria = {_fmt(p)} personas × {_fmt(d)} días × {AGUA_L_PERSONA_DIA} L = {_fmt(L)} litros como mínimo.")
    return out


# ---------- 3. RAG ----------
_INDEX = None
SPAIN = ("AESAN", "Balears", "Aragón", "Castilla", "Catalunya", "Murcia", "Madrid", "Valladolid", "Sanidad",
         "OCU", "SEFH", "Farmac", "Osakidetza", "Vasco", "Navarra", "Jaén", "e-distribución", "Nedgia",
         "Moncloa", "RTVE", "Onda Vasca", "Bomberos", "AEP", "Protecci")


def is_spain(d):
    return any(k in d["fuente"] for k in SPAIN)

# 2 nov: varias guías (CDC, Cruz Roja Americana, FCC) están en español de EE. UU. Para que el buscador
# las encuentre, a la pregunta se le añaden sus palabras equivalentes (solo para buscar; el modelo ve la pregunta original).
SINONIMOS = {
    r"lej[ií]a": "blanqueador con cloro",
    r"nevera|frigor[ií]fico": "refrigerador",
    r"\bm[oó]vil(es)?\b": "teléfono celular",
    r"\bgrifo\b": "agua de la llave",
    r"\bordenador": "computadora",
    r"\bcoche\b": "automóvil vehículo",
    r"\bv[aá]ter\b": "inodoro",
}


def expand(q):
    extra = [s for pat, s in SINONIMOS.items() if re.search(pat, q, re.I)]
    return q + (" (" + ", ".join(extra) + ")" if extra else "")


def retrieve(q, k=TOP_K):
    global _INDEX
    if _INDEX is None:
        _INDEX = json.load(open(INDEX, encoding="utf-8"))
    qv = embed([expand(q)], kind="query")[0]
    scored = sorted(_INDEX, key=lambda it: -sum(a * b for a, b in zip(qv, it["vec"])))
    top, n = [], {}
    for d in scored:  # los más parecidos, como mucho MAX_POR_FUENTE de cada guía
        if n.get(d["fuente"], 0) < MAX_POR_FUENTE:
            top.append(d); n[d["fuente"]] = n.get(d["fuente"], 0) + 1
        if len(top) == k: break
    return sorted(top, key=lambda d: not is_spain(d))  # v2: guías españolas primero (orden estable)


# ---------- 4. Todo junto ----------
def build_prompt(q):
    """Construye el mensaje de usuario exactamente como lo recibe el modelo (también para el fine-tuning)."""
    rules, calcs, docs = safety_rules(q), calculators(q), retrieve(q)
    parts = []
    if rules: parts.append("REGLAS DE SEGURIDAD:\n" + "\n".join(f"- {r}" for r in rules))
    if calcs: parts.append("DATOS CALCULADOS:\n" + "\n".join(f"- {c}" for c in calcs))
    parts.append("GUÍAS:\n" + "\n\n".join(f"[{i + 1}] ({d['fuente']}{' · España' if is_spain(d) else ''}) {d['texto']}" for i, d in enumerate(docs)))
    parts.append(f"PREGUNTA: {q}")
    meta = {"reglas": len(rules), "calculo": " | ".join(calcs),
            "fuentes_rag": " | ".join(d["fuente"][:50] for d in docs)}
    return "\n\n".join(parts), meta


def answer(model, q):
    user, meta = build_prompt(q)
    text, m = chat(model, user, system=SYSTEM_RAG)
    m.update(meta)
    return text, m
