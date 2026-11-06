"""Paso 6 · Exporta para la app iOS los datos del asistente, sacados de eval/pipeline.py (una sola fuente de verdad).

Escribe en app/Contenido/datos/:
  index.json   las guías troceadas con sus vectores (copia de rag/index.json)
  reglas.json  mensaje de sistema, reglas de seguridad, sinónimos, guías españolas y constantes de las calculadoras
  modelos.json qué modelos descarga la app la primera vez (URL de Hugging Face, tamaño y huella SHA-256)
  casos.json   lo que da Python para cada pregunta del golden set, del test y de la demo: sirve para comprobar
               que la versión en Swift hace exactamente lo mismo (app/check y el botón «Autocomprobación»)

Uso (en el Mac, con Ollama abierto):   python3 app/exportar_datos.py
Sin Ollama (no guarda los trozos que encuentra la búsqueda):   python3 app/exportar_datos.py --sin-busqueda
"""
import hashlib, json, os, re, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "eval"))
import pipeline  # noqa: E402
import embed  # noqa: E402
from common import GOLDEN, read_csv  # noqa: E402

OUT = os.path.join(HERE, "Contenido", "datos")
MODELOS = os.path.join(HERE, "Modelos")   # en el Mac; la app los descarga de Hugging Face
REPO_F = os.path.join(HERE, "hf_repo.txt")  # lo escribe finetune/publicar_hf.sh
EXTRA = [  # demo y cálculos que no salen en los sets
    "Se ha ido la luz hace 3 horas, ¿la comida de la nevera sigue siendo segura?",
    "Somos 4 en casa, ¿cuánta agua necesitamos para 3 días?",
    "¿Qué emisora de radio sigo durante el apagón y cómo la escucho sin luz?",
    "Tengo una power bank de 10.000 mAh y mi móvil tiene 4000 mAh, ¿cuántas cargas me da?",
    "Tengo dos power banks de 5000 mAh y un móvil de 3000 mAh, ¿cuántas cargas?",
    "Somos 3 y tenemos 6 litros de agua, ¿para cuántos días llega?",
    "El congelador medio lleno lleva 30 horas sin luz, ¿qué hago?",
    "Llevo 1,5 horas sin luz, ¿la leche de la nevera está bien?",
    "La carne congelada lleva 50 horas sin luz",
    "Somos cinco personas, ¿cuánta agua para siete días?",
]


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()


def lista_modelos():
    """Qué descarga la app la primera vez: archivo, URL, tamaño y huella SHA-256 (de los archivos de app/Modelos)."""
    repo = open(REPO_F).read().strip() if os.path.exists(REPO_F) else ""
    if not repo:
        print("   ! falta app/hf_repo.txt: publica antes el modelo con  bash finetune/publicar_hf.sh")
        repo = "PENDIENTE/ministral3-apagon-GGUF"
    modelos = [
        {"id": "generador", "nombre": "el asistente (Ministral 3 3B afinado)", "archivo": "ministral3-apagon.Q4_K_M.gguf",
         "url": f"https://huggingface.co/{repo}/resolve/main/ministral3-apagon.Q4_K_M.gguf"},
        {"id": "vectores", "nombre": "el buscador de las guías (EmbeddingGemma)", "archivo": "embeddinggemma-300M-Q8_0.gguf",
         "url": "https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf"},
    ]
    for m in modelos:
        p = os.path.join(MODELOS, m["archivo"])
        m["bytes"] = os.path.getsize(p)
        print(f"   calculando la huella de {m['archivo']}…")
        m["sha256"] = sha256(p)
    return modelos


def main():
    os.makedirs(OUT, exist_ok=True)
    json.dump(lista_modelos(), open(os.path.join(OUT, "modelos.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    shutil.copy(pipeline.INDEX, os.path.join(OUT, "index.json"))
    datos = {
        "system_rag": pipeline.SYSTEM_RAG,
        "reglas": [{"patron": p, "texto": t} for p, t in pipeline.RULES],
        "sinonimos": [{"patron": p, "extra": s} for p, s in pipeline.SINONIMOS.items()],
        "espana": list(pipeline.SPAIN),
        "top_k": pipeline.TOP_K,
        "max_por_fuente": pipeline.MAX_POR_FUENTE,
        "prefijo_consulta": embed.PREFIX["query"],
        "num": pipeline.NUM,
        "palabras_numero": pipeline.WORDNUM,
        "constantes": {
            "eficiencia_pb": pipeline.EFICIENCIA_PB, "eficiencia_pb_txt": str(pipeline.EFICIENCIA_PB),
            "agua": pipeline.AGUA_L_PERSONA_DIA, "agua_txt": str(pipeline.AGUA_L_PERSONA_DIA),
            "nevera_h": pipeline.NEVERA_H, "congelador_lleno_h": pipeline.CONGELADOR_LLENO_H,
            "congelador_medio_h": pipeline.CONGELADOR_MEDIO_H,
        },
    }
    json.dump(datos, open(os.path.join(OUT, "reglas.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    preguntas = ([r["pregunta"] for r in read_csv(GOLDEN)]
                 + [r["pregunta"] for r in read_csv(os.path.join(ROOT, "data", "test_set.csv"))] + EXTRA)
    busqueda = "--sin-busqueda" not in sys.argv
    indice = json.load(open(pipeline.INDEX, encoding="utf-8"))
    pipeline._INDEX = indice
    posicion = {id(d): i for i, d in enumerate(indice)}
    casos = []
    for n, q in enumerate(preguntas, 1):
        c = {"q": q,
             "reglas": [i for i, (p, _) in enumerate(pipeline.RULES) if re.search(p, q.lower())],
             "calculos": pipeline.calculators(q),
             "expandida": pipeline.expand(q)}
        if busqueda:
            c["top"] = [posicion[id(d)] for d in pipeline.retrieve(q)]
        casos.append(c)
        print(f"   {n}/{len(preguntas)}", end="\r")
    json.dump(casos, open(os.path.join(OUT, "casos.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"\n→ {OUT}: index.json ({len(indice)} trozos), reglas.json ({len(pipeline.RULES)} reglas), casos.json ({len(casos)} preguntas)")


if __name__ == "__main__":
    main()
