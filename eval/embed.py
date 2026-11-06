"""Embeddings con EmbeddingGemma vía Ollama (/api/embed)."""
import json, math, urllib.request
from common import OLLAMA

EMBED_MODEL = "embeddinggemma"
# Prefijos recomendados para EmbeddingGemma (búsqueda: consulta vs documento)
PREFIX = {"query": "task: search result | query: ", "doc": "title: none | text: "}


def embed(texts, kind="query"):
    body = {"model": EMBED_MODEL, "input": [PREFIX[kind] + t for t in texts]}
    req = urllib.request.Request(f"{OLLAMA}/api/embed", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    vecs = json.load(urllib.request.urlopen(req, timeout=300))["embeddings"]
    return [_norm(v) for v in vecs]


def _norm(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]
