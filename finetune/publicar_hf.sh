#!/usr/bin/env bash
# Publica el modelo afinado en Hugging Face (repo público) y guarda el nombre del repo para la app.
#
#   cd ~/Documents/PTA/"PTA - Eric Sans"/proyecto-apagon
#   bash finetune/publicar_hf.sh
#
# El token NO se guarda en el proyecto: la primera vez «hf auth login» lo pide y lo guarda en ~/.cache/huggingface.
# Hace falta un token con permiso de escritura (Write).
set -euo pipefail
cd "$(dirname "$0")/.."                      # carpeta proyecto-apagon
GGUF=finetune/build/ministral3-apagon.Q4_K_M.gguf
NOMBRE=ministral3-apagon-GGUF
[ -f "$GGUF" ] || { echo "Falta $GGUF (paso 5)"; exit 1; }

# Python 3.12 del paso 5 (el python3 del sistema es 3.9)
if [ ! -x "$HOME/venv-gguf/bin/python" ]; then
  "$(brew --prefix)/bin/python3.12" -m venv "$HOME/venv-gguf"
fi
PY="$HOME/venv-gguf/bin/python"
"$PY" -m pip install -q -U huggingface_hub

if ! "$PY" -c "from huggingface_hub import whoami; whoami()" >/dev/null 2>&1; then
  echo "Pega tu token de Hugging Face (Write) cuando lo pida:"
  "$HOME/venv-gguf/bin/hf" auth login
fi

REPO=$("$PY" -c "from huggingface_hub import whoami; print(whoami()['name'])")/$NOMBRE
echo "Publicando en https://huggingface.co/$REPO (2,1 GB: tarda según tu conexión)…"
"$PY" - "$REPO" "$GGUF" <<'EOF'
import sys
from huggingface_hub import HfApi
repo, gguf = sys.argv[1], sys.argv[2]
api = HfApi()
api.create_repo(repo, repo_type="model", exist_ok=True)
api.upload_file(path_or_fileobj="finetune/hf/README.md", path_in_repo="README.md", repo_id=repo,
                commit_message="Ficha del modelo")
api.upload_file(path_or_fileobj=gguf, path_in_repo="ministral3-apagon.Q4_K_M.gguf", repo_id=repo,
                commit_message="Ministral 3 3B afinado para apagones (GGUF Q4_K_M)")
print("Subido.")
EOF

echo "$REPO" > app/hf_repo.txt
echo
echo "Listo: https://huggingface.co/$REPO"
echo "La app descargará el modelo de ahí. Ahora vuelve a preparar la app:  bash app/preparar.sh"
