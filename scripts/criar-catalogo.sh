#!/usr/bin/env bash
# Cria o catálogo lakehouse_rotaperfume. Roda UMA vez, antes do primeiro
# `databricks bundle deploy`.
#
# Por que este script existe fora do bundle: no Databricks Free Edition o
# Default Storage vem ligado por padrão, e nessa configuração a API do Unity
# Catalog (o `resources.schemas`/`catalog` do bundle) RECUSA criar catálogo —
# ela exige um MANAGED LOCATION que a conta gratuita não tem para oferecer:
#
#   Error: Metastore storage root URL does not exist.
#          Default Storage is enabled in your account. (400 INVALID_STATE)
#
# O comando SQL `CREATE CATALOG`, esse funciona sem restrição. Por isso o
# catálogo nasce aqui, via warehouse, e todo o resto (schemas, volume, job,
# dashboard, Genie) nasce como recurso do bundle em resources/.
#
# Uso: bash scripts/criar-catalogo.sh <profile>
set -euo pipefail

PROFILE="${1:?uso: bash scripts/criar-catalogo.sh <profile>}"
CATALOGO="${2:-lakehouse_rotaperfume}"

echo "CREATE CATALOG IF NOT EXISTS $CATALOGO
      COMMENT 'Rota do Perfume — distribuidora B2B de perfumaria árabe. Imersão Jornada de Dados, noite 2.'" \
  | databricks experimental aitools tools query --profile "$PROFILE"

echo "catálogo $CATALOGO pronto."
