#!/usr/bin/env bash
# Sobe os CSVs de ERP e CRM para o Volume bronze.raw do Unity Catalog.
# Roda DEPOIS do deploy — é o deploy que cria o Volume.
#
# Uso: bash scripts/subir-raw.sh <profile>
#
# Duas pegadinhas de quem faz isso pela primeira vez:
#   1. `databricks fs cp` exige o esquema `dbfs:` no destino, mesmo o destino
#      sendo um Volume do Unity Catalog e não o DBFS de fato.
#   2. O dataset nasce com seed fixa (42): todo mundo que rodar este script
#      sobe exatamente o mesmo dado e chega no mesmo número no final da noite.
set -euo pipefail

PROFILE="${1:?informe o profile: bash scripts/subir-raw.sh <profile>}"
CATALOGO="${2:-lakehouse_rotaperfume}"

# scripts/ -> rotaperfume_meu_ensaio -> aula-02-engenharia-de-dados -> aulas -> raiz do repositório
RAIZ="$(cd "$(dirname "$0")/../../../.." && pwd)"
DADOS="$RAIZ/dados"
DESTINO="dbfs:/Volumes/$CATALOGO/bronze/raw"

if [ ! -d "$DADOS/erp" ]; then
  echo "dados/ não existe — gerando com seed 42..."
  python3 "$RAIZ/material/gerar_dataset.py" --saida "$DADOS" --seed 42
fi

for sistema in erp crm; do
  echo "→ subindo $sistema"
  databricks fs cp --recursive --overwrite "$DADOS/$sistema" "$DESTINO/$sistema" --profile "$PROFILE"
done

echo
databricks fs ls "$DESTINO/erp" --profile "$PROFILE"
databricks fs ls "$DESTINO/crm" --profile "$PROFILE"
