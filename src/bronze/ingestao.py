# Databricks notebook source
# MAGIC %md
# MAGIC # Bronze · ingestão
# MAGIC
# MAGIC Os dez CSVs conferidos na tarefa anterior viram dez tabelas Delta aqui.
# MAGIC **Nenhuma limpeza acontece nesta camada.**
# MAGIC
# MAGIC Tudo entra como `string`, de propósito: `inferSchema` transformaria uma
# MAGIC data quebrada em `null` e apagaria os zeros à esquerda de um CNPJ antes de
# MAGIC alguém ver que a sujeira existia. Converter tipo é trabalho da silver,
# MAGIC feito sabendo exatamente o que está sendo corrigido.
# MAGIC
# MAGIC Cada tabela ganha só duas colunas a mais: `_ingerido_em` (quando isso
# MAGIC entrou na bronze) e `_arquivo_origem` (de qual CSV veio).

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_rotaperfume")
catalog = dbutils.widgets.get("catalog")

CAMINHO_RAW = f"/Volumes/{catalog}/bronze/raw"

# sistema, tabela, comentário de origem — uma linha por CSV que o ERP e o CRM
# combinaram entregar. Amanhã uma décima primeira tabela é uma linha aqui, não
# um bloco de código novo.
TABELAS = [
    ("erp", "produtos",      "Catálogo de SKUs do ERP: marca, categoria, nota olfativa, custo e preço."),
    ("erp", "pedidos",       "Cabeçalho de pedido do ERP: cliente, vendedor, canal, status e valor."),
    ("erp", "itens_pedido",  "Item de pedido do ERP: SKU, quantidade, preço praticado e desconto."),
    ("erp", "pagamentos",    "Financeiro do ERP: forma de pagamento, parcelas, taxa, vencimento e baixa."),
    ("erp", "estoque",       "Snapshot semanal de saldo por SKU no ERP, com marcação de ruptura."),
    ("crm", "clientes",      "Cadastro de clientes do CRM: CNPJ, razão social, segmento e cidade."),
    ("crm", "vendedores",    "Equipe comercial do CRM: região, admissão, desligamento e meta."),
    ("crm", "carteira",      "Vínculo cliente × vendedor no CRM, com data de vigência."),
    ("crm", "oportunidades", "Funil comercial do CRM: origem, etapa, valor estimado e motivo de perda."),
    ("crm", "visitas",       "Visitas registradas pelo CRM: data, resultado e duração."),
]

# COMMAND ----------

from pyspark.sql import functions as F


def ingerir(sistema: str, tabela: str, comentario: str) -> int:
    """Lê um CSV do Volume raw e grava a tabela bronze correspondente, tudo texto."""
    origem = f"{CAMINHO_RAW}/{sistema}/{tabela}.csv"
    destino = f"{catalog}.bronze.{tabela}"

    df = (
        spark.read
        .option("header", True)
        .option("inferSchema", False)  # a decisão da camada inteira: nada de tipo adivinhado
        .csv(origem)
        .withColumn("_ingerido_em", F.current_timestamp())
        .withColumn("_arquivo_origem", F.col("_metadata.file_path"))
    )

    df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(destino)
    spark.sql(f"COMMENT ON TABLE {destino} IS '{comentario} Ingerida como texto, sem limpeza — camada bronze.'")

    return spark.table(destino).count()


contagens = {tabela: ingerir(sistema, tabela, comentario) for sistema, tabela, comentario in TABELAS}

# COMMAND ----------

# Fecha o ciclo com a conferência do prompt anterior: o que a bronze gravou
# precisa bater exatamente com o que o arquivo trouxe (linhas do CSV menos o
# header, já calculado por bronze._raw_arquivos). Se não bater, alguma linha
# se perdeu ou duplicou na leitura — melhor descobrir aqui do que no dashboard.
esperado = {
    r.arquivo.replace(".csv", ""): r.linhas
    for r in spark.table(f"{catalog}.bronze._raw_arquivos").collect()
}

print(f"{'tabela':<16} {'no arquivo':>12} {'na bronze':>12}   ")
print("-" * 48)

divergencias = []
for _, tabela, _ in TABELAS:
    linhas_arquivo = esperado.get(tabela)
    linhas_bronze = contagens[tabela]
    marca = "ok" if linhas_arquivo == linhas_bronze else "DIVERGIU"
    if linhas_arquivo != linhas_bronze:
        divergencias.append(f"{tabela}: arquivo {linhas_arquivo}, bronze {linhas_bronze}")
    print(f"{tabela:<16} {linhas_arquivo:>12,} {linhas_bronze:>12,}   {marca}")

print("-" * 48)
print(f"{'TOTAL':<16} {sum(esperado.values()):>12,} {sum(contagens.values()):>12,}")

if divergencias:
    raise Exception("Contagem não bate entre arquivo e tabela bronze: " + "; ".join(divergencias))

print("\nOK — as 10 tabelas bronze batem com o que chegou no raw")
