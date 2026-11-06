#!/usr/bin/env bash
# Paso 6 · Prepara la app iOS en el Mac. Se puede relanzar: lo que ya está hecho se salta.
#
#   cd ~/Documents/PTA/"PTA - Eric Sans"/proyecto-apagon
#   bash app/preparar.sh
#
# Necesita: Xcode, Homebrew (cmake y xcodegen), Ollama abierto (para exportar los datos), internet la primera vez y el modelo afinado en
# finetune/build/ministral3-apagon.Q4_K_M.gguf
set -euo pipefail
cd "$(dirname "$0")"          # carpeta app/
LLAMA_TAG=b12038              # versión fija de llama.cpp (2 nov 2026), para que sea reproducible

echo "== 1/5 · Herramientas"
for h in cmake xcodegen; do
  command -v "${h}" >/dev/null || { echo "   instalando ${h}..."; brew install "${h}"; }
done

echo "== 2/5 · llama.cpp para iOS (simulador + iPhone): la primera vez tarda ~10–20 min"
if [ ! -d vendor/llama.cpp/build-apple/llama.xcframework ]; then
  rm -rf vendor/llama.cpp
  git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp vendor/llama.cpp
  (cd vendor/llama.cpp && ./build-xcframework.sh ios-sim ios-device)
else
  echo "   ya está: vendor/llama.cpp/build-apple/llama.xcframework"
fi

echo "== 3/5 · Modelos (en app/Modelos: NO van dentro de la app, que los descarga de Hugging Face la primera vez)"
# versiones anteriores de este script los guardaban dentro de la app
if [ -d Resources ] && [ ! -d Contenido ]; then mv Resources Contenido; fi
mkdir -p Modelos
if [ -f Contenido/modelos/ministral3-apagon.Q4_K_M.gguf ]; then mv -f Contenido/modelos/ministral3-apagon.Q4_K_M.gguf Modelos/; fi
if [ -f Contenido/modelos/embeddinggemma.gguf ]; then mv -f Contenido/modelos/embeddinggemma.gguf Modelos/embeddinggemma-300M-Q8_0.gguf; fi
rmdir Contenido/modelos 2>/dev/null || true
MODELO=../finetune/build/ministral3-apagon.Q4_K_M.gguf
if [ ! -f Modelos/ministral3-apagon.Q4_K_M.gguf ]; then
  [ -f "$MODELO" ] || { echo "   falta $MODELO (paso 5)"; exit 1; }
  cp -c "$MODELO" Modelos/ 2>/dev/null || cp "$MODELO" Modelos/   # -c: copia instantánea en APFS
fi
# EmbeddingGemma para llama.cpp (arquitectura «gemma-embedding», con sus capas densas).
# El archivo que guarda Ollama NO sirve: es arquitectura «gemma3» sin esas capas y llama.cpp no lo carga bien.
EMB_URL="https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf"
EMB=Modelos/embeddinggemma-300M-Q8_0.gguf
arquitectura() { python3 -c "
import struct,sys
f=open(sys.argv[1],'rb'); f.read(8); n,kv=struct.unpack('<QQ',f.read(16))
ln,=struct.unpack('<Q',f.read(8)); k=f.read(ln).decode(); t,=struct.unpack('<I',f.read(4)); ln,=struct.unpack('<Q',f.read(8))
print(f.read(ln).decode() if k=='general.architecture' else '?')" "$1" 2>/dev/null || echo "?"; }
if [ ! -f "$EMB" ] || [ "$(arquitectura "$EMB")" != "gemma-embedding" ]; then
  echo "   descargando EmbeddingGemma para llama.cpp (~330 MB)..."
  curl -L --fail -o "$EMB" "$EMB_URL" || { echo "   ! no se pudo descargar: bájalo a mano de https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF y guárdalo como app/$EMB"; exit 1; }
fi
echo "   EmbeddingGemma: arquitectura $(arquitectura "$EMB")"
ls -lh Modelos

echo "== 4/5 · Datos del asistente (desde eval/pipeline.py) y lista de modelos para descargar"
python3 exportar_datos.py

echo "== 5/5 · Comprobación en Swift (sin simulador) y proyecto de Xcode"
mkdir -p build
swiftc -O Sources/Pipeline.swift check/main.swift -o build/check
build/check Contenido/datos
xcodegen generate
echo
echo "Listo. Abre app/Apagon.xcodeproj, elige un simulador de iPhone y pulsa ▶ (Cmd+R)."
