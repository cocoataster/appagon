"""Paso 4 · Construye el índice RAG local a partir de las guías oficiales.

1. Saca las URLs de la columna «fuente» del golden set (son las guías oficiales que usamos).
2. Las descarga en data/guias/raw/ y extrae el texto a data/guias/texto/.
3. Trocea el texto y calcula embeddings con EmbeddingGemma (Ollama).
4. Guarda rag/index.json (lo que se empaquetará en la app).

Uso (una vez):
    pip3 install --user pypdf          # para leer los PDF
    ollama pull embeddinggemma
    python3 rag/build_index.py
Guías que la web no deja descargar: guárdalas desde el navegador (PDF, HTML o TXT) en
data/guias/manual/ con un nombre descriptivo (p. ej. «CDC · Agua segura en emergencias.pdf»)
y vuelve a lanzarlo: el nombre del archivo se usa como fuente. Lo ya descargado no se repite.
"""
import hashlib, html, json, logging, os, re, sys, urllib.parse, urllib.request
logging.getLogger("pypdf").setLevel(logging.ERROR)  # silencia avisos de fuentes de los PDF
from html.parser import HTMLParser

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "eval"))
from common import ROOT, GOLDEN, read_csv  # noqa: E402
from embed import embed  # noqa: E402

RAW = os.path.join(ROOT, "data", "guias", "raw")
TXT = os.path.join(ROOT, "data", "guias", "texto")
MANUAL = os.path.join(ROOT, "data", "guias", "manual")
INDEX = os.path.join(ROOT, "rag", "index.json")
CHUNK, OVERLAP = 700, 120  # caracteres
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15"


def urls_from_golden():
    found = {}
    for r in read_csv(GOLDEN):
        parts = [p.strip() for p in r["fuente"].split(" · ")]
        start = 0
        for i, p in enumerate(parts):
            if p.startswith("http"):
                p = p.split()[0]  # quita notas tras la URL, p. ej. «(conversión a litros propia)»
                name = " · ".join(parts[start:i]) or p   # texto entre la URL anterior y esta
                found.setdefault(p, name)
                start = i + 1
    return found


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(); self.out, self.skip = [], 0
    def handle_starttag(self, tag, a):
        if tag in ("script", "style", "nav", "footer", "header", "noscript"): self.skip += 1
        if tag in ("p", "li", "br", "h1", "h2", "h3", "h4", "tr", "div"): self.out.append("\n")
    def handle_endtag(self, tag):
        if tag in ("script", "style", "nav", "footer", "header", "noscript") and self.skip: self.skip -= 1
    def handle_data(self, d):
        if not self.skip: self.out.append(d)


def fetch(url, hops=5):
    """Descarga siguiendo redirecciones, también 307/308 (Python 3.9 no las sigue solo)."""
    for _ in range(hops):
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "es-ES,es;q=0.9"})
        try:
            return urllib.request.urlopen(req, timeout=30)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
                url = urllib.parse.urljoin(url, e.headers["Location"]); continue
            raise
    raise RuntimeError("demasiadas redirecciones")


def to_text(data, is_pdf):
    if is_pdf:
        try:
            from pypdf import PdfReader
        except ImportError:
            print("   ! falta pypdf: pip3 install --user pypdf"); return ""
        import io
        return "\n".join((p.extract_text() or "") for p in PdfReader(io.BytesIO(data)).pages)
    p = _Text(); p.feed(data.decode("utf-8", errors="ignore"))
    return html.unescape("".join(p.out))


def clean(t):
    t = re.sub(r"[ \t ]+", " ", t)
    t = re.sub(r"\n\s*\n+", "\n\n", t)
    return t.strip()


# ---------- Limpieza de texto basura de las webs (revisión manual del 2 nov) ----------
# Corta el texto desde la primera marca: lo que sigue es menú, noticias, publicidad o avisos legales.
CUT_AT = [
    r"\n\s*Lo más leído",                                # Selectra: noticias, autor, cookies y privacidad
    r"Etiquetas\s+Electricidad",                         # Onda Vasca: noticias de la web
    r"Sara Duque \(Barcelona",                           # The Objective: firma y noticias
    r"Comparte X / Twitter",                             # DPL News: noticias de telecomunicaciones
    r"Subscribe to the WorldDAB newsletter",             # WorldDAB: noticias de Senegal y Dakar
    r"LISTADOS TELEFONICOS",                             # Universidad de Jaén: teléfonos del campus
    r"Para más información \(medios de comunicación\)",  # OCU: contacto de prensa y avisos legales
    r"Descubre información clave sobre lo que te interesa",  # OCU: cookies y artículos relacionados
    r"Lista de verificación disponible en varios idiomas",   # Cruz Roja: idiomas y app
    r"Sources and Page Info",                            # CDC: pie de página
    r"How to activate trickle",                          # Anker: tienda y menús
    r"\bSwitching Insulin\b",                            # FDA: cambio de insulina con dosis (la app no da dosis)
    r"Las cookies utilizadas",                           # Murciasalud: aviso de cookies
]
# Borra solo el fragmento (el resto del texto se conserva).
REMOVE = [
    r"Win a Mystery Box.*?Go to Anker SOLIX",                       # Anker: promoción y menú
    r"Desde OCU deseamos informarte.*?\]\}",                        # OCU: cookies y menú en JSON
    r"Contáctanos\s+Whatsapp.*?Vida y estilo",                      # Onda Vasca: menú
    r"¿[^?¿]{0,80}\?\s*En Selectra te ayudamos[^.]*\.",             # Selectra: anuncios
    r"¿[^?¿]{0,80}\?\s*Comparamos tu tarifa[^.]*\.\s*Solicita tu estudio de factura gratuito\.",
    r"[^.]*they may call the manufacturer.*?official website\.",    # FDA: teléfonos de fabricantes de EE. UU.
    r"Corredor, la presidenta .{0,80}?tras el apagón",              # The Objective: enlace a otra noticia
    r"[^.\n]*\bcookies?\b[^.\n]*\.?",                               # cualquier frase sobre cookies
]


def strip_junk(t):
    for pat in CUT_AT:
        m = re.search(pat, t)
        if m and m.start() > 200:
            t = t[:m.start()]
    for pat in REMOVE:
        t = re.sub(pat, " ", t, flags=re.S)
    return clean(t)


def _split_long(p):
    """Un párrafo más largo que CHUNK (p. ej. una página de PDF entera) se parte por frases."""
    if len(p) <= CHUNK:
        return [p]
    out, buf = [], ""
    for s in re.split(r"(?<=[.!?;:])\s+", p):
        while len(s) > CHUNK:            # frase sin puntos (tablas de PDF): corte duro
            out.append((buf + " " + s[:CHUNK]).strip()); buf = ""; s = s[CHUNK:]
        if len(buf) + len(s) > CHUNK and buf:
            out.append(buf); buf = s
        else:
            buf = (buf + " " + s).strip()
    if buf: out.append(buf)
    return out


def chunks(text):
    paras = [q for p in text.split("\n\n") if len(p.strip()) > 40 for q in _split_long(p.strip())]
    buf, out = "", []
    for p in paras:
        if len(buf) + len(p) > CHUNK and buf:
            out.append(buf); buf = buf[-OVERLAP:] + " " + p
        else:
            buf = (buf + "\n" + p).strip()
    if buf: out.append(buf)
    return out


def main():
    os.makedirs(RAW, exist_ok=True); os.makedirs(TXT, exist_ok=True)
    sources = urls_from_golden()
    print(f"{len(sources)} fuentes en el golden set")
    meta = {}
    for url, name in sources.items():
        slug = hashlib.md5(url.encode()).hexdigest()[:10]
        txt_path = os.path.join(TXT, slug + ".txt")
        meta[slug] = {"url": url, "fuente": name}
        if os.path.exists(txt_path):
            print(f" = {name[:60]}"); continue
        try:
            resp = fetch(url)
            data = resp.read()
            is_pdf = data[:4] == b"%PDF" or "pdf" in resp.headers.get("Content-Type", "")
            open(os.path.join(RAW, slug + (".pdf" if is_pdf else ".html")), "wb").write(data)
            text = clean(to_text(data, is_pdf))
            if len(text) < 200:
                print(f" ! poco texto ({len(text)} car.): {name[:60]}"); continue
            if re.search(r"captcha|are you a robot|you are a bot|access denied", text[:2000], re.I):
                print(f" ! página de bloqueo (captcha), no es la guía: {name[:60]}"); continue
            open(txt_path, "w", encoding="utf-8").write(text)
            print(f" + {name[:60]}  ({len(text)} car.)")
        except Exception as e:
            print(f" ! no se pudo descargar: {name[:60]} → {e}")
    # Guías guardadas a mano desde el navegador
    os.makedirs(MANUAL, exist_ok=True)
    for f in sorted(os.listdir(MANUAL)):
        path = os.path.join(MANUAL, f)
        name, ext = os.path.splitext(f)
        if ext.lower() not in (".pdf", ".html", ".htm", ".txt"):
            continue
        slug = "manual_" + hashlib.md5(f.encode()).hexdigest()[:10]
        meta[slug] = {"url": "(guardada a mano)", "fuente": name}
        txt_path = os.path.join(TXT, slug + ".txt")
        if os.path.exists(txt_path):
            print(f" = {name[:60]} (manual)"); continue
        data = open(path, "rb").read()
        text = data.decode("utf-8", errors="ignore") if ext.lower() == ".txt" else to_text(data, ext.lower() == ".pdf")
        text = clean(text)
        if len(text) < 200:
            print(f" ! poco texto ({len(text)} car.): {name[:60]} (manual)"); continue
        open(txt_path, "w", encoding="utf-8").write(text)
        print(f" + {name[:60]} (manual, {len(text)} car.)")
    json.dump(meta, open(os.path.join(TXT, "_fuentes.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    items = []
    for f in sorted(os.listdir(TXT)):
        if not f.endswith(".txt"): continue
        slug = f[:-4]
        m = meta.get(slug, {"url": "", "fuente": slug})
        for c in chunks(strip_junk(open(os.path.join(TXT, f), encoding="utf-8").read())):
            items.append({"fuente": m["fuente"], "url": m["url"], "texto": c})
    print(f"\n{len(items)} trozos. Calculando embeddings…")
    vecs = []
    for i in range(0, len(items), 32):
        vecs += embed([it["texto"] for it in items[i:i + 32]], kind="doc")
        print(f"   {min(i + 32, len(items))}/{len(items)}", end="\r")
    for it, v in zip(items, vecs):
        it["vec"] = [round(x, 5) for x in v]
    json.dump(items, open(INDEX, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"\n→ {INDEX}  ({os.path.getsize(INDEX) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
