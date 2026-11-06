"""Plan B sin GPU: fusiona el adaptador LoRA (descargado de Colab) con Ministral 3 3B en el Mac.

Requisitos: pip install "transformers>=5" peft torch torchvision accelerate safetensors sentencepiece mistral-common
Uso:  python finetune/merge_lora.py [ruta/a/ministral3-apagon-lora.zip]
Salida: finetune/build/merged/  (modelo fusionado en 16 bits, listo para convertir a GGUF con llama.cpp)
"""
import os, sys, zipfile
import torch
from transformers import AutoModelForImageTextToText, AutoProcessor
from peft import PeftModel

BASE = "unsloth/Ministral-3-3B-Instruct-2512"  # mismo modelo base que en Colab, en 16 bits
HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
zip_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Downloads/ministral3-apagon-lora.zip")
lora_dir = os.path.join(BUILD, "ministral3-apagon-lora")
out = os.path.join(BUILD, "merged")

os.makedirs(BUILD, exist_ok=True)
if not os.path.isdir(lora_dir):
    print("Descomprimiendo", zip_path)
    zipfile.ZipFile(zip_path).extractall(BUILD)

if os.path.isdir(out) and any(f.endswith(".safetensors") for f in os.listdir(out)):
    print("El modelo fusionado ya existe; solo se guarda el tokenizador.")
else:
    print("Cargando el modelo base (descarga ~7,7 GB la primera vez)…")
    model = AutoModelForImageTextToText.from_pretrained(BASE, dtype=torch.bfloat16)
    print("Aplicando y fusionando el adaptador LoRA…")
    model = PeftModel.from_pretrained(model, lora_dir).merge_and_unload()
    model.save_pretrained(out, safe_serialization=True)
AutoProcessor.from_pretrained(lora_dir).save_pretrained(out)  # tokenizador con el arreglo del regex
print("Listo →", out)
