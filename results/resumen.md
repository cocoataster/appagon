| Modelo | Correctas | Parciales | Peligrosas | Numéricas | Trampas seguras | Tokens/s (Mac) | Tokens/resp. | Segundos/resp. (Mac) |
|---|---|---|---|---|---|---|---|---|
| gemma4-e2b · base | 23 % | 60 % | 6 | 28 % | 8/10 | 114 | 39 | 0.6 |
| ministral-3b · base | 22 % | 41 % | 19 | 44 % | 8/10 | 106 | 82 | 0.9 |
| qwen3.5-2b · base | 11 % | 41 % | 25 | 31 % | 7/10 | 107 | 51 | 0.7 |
| salamandra-2b · base | 13 % | 32 % | 19 | 22 % | 6/10 | 180 | 24 | 0.3 |
| gemma4-e2b · RAG v1 | 49 % | 36 % | 4 | 84 % | 10/10 | 159 | 44 | 0.8 |
| ministral-3b · RAG v1 | 59 % | 27 % | 6 | 100 % | 8/10 | 103 | 88 | 1.3 |
| gemma4-e2b · RAG v2 | 57 % | 34 % | 3 | 84 % | 10/10 | 157 | 44 | 0.9 |
| ministral-3b-ft · RAG v2 | 53 % | 34 % | 3 | 88 % | 10/10 | 100 | 47 | 1.0 |
| ministral-3b · RAG v2 | 59 % | 26 % | 5 | 84 % | 10/10 | 99 | 97 | 1.7 |
| gemma4-e2b · TEST (RAG v2) | 48 % | 45 % | 3 | 71 % | 17/20 | 153 | 45 | 1.0 |
| ministral-3b-ft · TEST (RAG v2) | 52 % | 41 % | 1 | 86 % | 19/20 | 100 | 44 | 1.2 |
| ministral-3b · TEST (RAG v2) | 62 % | 29 % | 3 | 71 % | 18/20 | 99 | 87 | 1.7 |

**Correctas por categoría**

| Categoría | gemma4-e2b · RAG v1 | gemma4-e2b · RAG v2 | gemma4-e2b · TEST (RAG v2) | gemma4-e2b · base | ministral-3b · RAG v1 | ministral-3b · RAG v2 | ministral-3b · TEST (RAG v2) | ministral-3b · base | ministral-3b-ft · RAG v2 | ministral-3b-ft · TEST (RAG v2) | qwen3.5-2b · base | salamandra-2b · base |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| comida_nevera | 67 % | 75 % | 80 % | 25 % | 83 % | 75 % | 80 % | 25 % | 75 % | 80 % | 8 % | 8 % |
| agua | 67 % | 75 % | 60 % | 17 % | 75 % | 67 % | 60 % | 25 % | 75 % | 40 % | 17 % | 25 % |
| energia | 33 % | 50 % | 50 % | 8 % | 42 % | 50 % | 50 % | 8 % | 42 % | 50 % | 0 % | 0 % |
| comunicacion | 33 % | 33 % | 50 % | 17 % | 42 % | 42 % | 83 % | 25 % | 42 % | 50 % | 17 % | 17 % |
| seguridad | 33 % | 25 % | 40 % | 17 % | 33 % | 50 % | 60 % | 8 % | 33 % | 40 % | 0 % | 8 % |
| frio_calor | 33 % | 50 % | 25 % | 25 % | 42 % | 50 % | 25 % | 17 % | 25 % | 25 % | 8 % | 17 % |
| preparacion | 58 % | 58 % | 80 % | 33 % | 75 % | 58 % | 60 % | 33 % | 58 % | 60 % | 8 % | 8 % |
| trampa | 70 % | 100 % | 35 % | 50 % | 80 % | 80 % | 65 % | 40 % | 80 % | 55 % | 30 % | 20 % |
