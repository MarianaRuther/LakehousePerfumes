# Databricks notebook source
# MAGIC %md
# MAGIC # Conferência de chegada do raw
# MAGIC
# MAGIC Antes de qualquer ingestão, uma pergunta chata mas decisiva: **os dez
# MAGIC arquivos que o ERP e o CRM prometeram entregar hoje realmente chegaram,
# MAGIC e vieram com dado dentro?**
# MAGIC
# MAGIC Arquivo que falta não quebra o pipeline sozinho — ele só faz a receita
# MAGIC dar um número menor, e ninguém percebe até o fim do mês. Por isso esta
# MAGIC tarefa roda primeiro, antes de qualquer linha virar tabela: se faltar
# MAGIC arquivo, o pipeline para aqui, e o dashboard continua mostrando o dado
# MAGIC de ontem em vez do dado incompleto de hoje.
# MAGIC
# MAGIC Esta tarefa não olha para dentro das colunas — isso é trabalho da bronze.
# MAGIC Ela só confere: o arquivo existe, tem tamanho e tem linha.

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_rotaperfume")
catalog = dbutils.widgets.get("catalog")

CAMINHO_RAW = f"/Volumes/{catalog}/bronze/raw"

# Os dez arquivos combinados com ERP e CRM para a entrega diária.
ARQUIVOS_ESPERADOS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

# COMMAND ----------

from pyspark.sql import functions as F

registros = []
arquivos_faltando = []
arquivos_vazios = []

for sistema, tabelas in ARQUIVOS_ESPERADOS.items():
    # dbutils.fs.ls levanta exceção se a pasta não existir — e isso já é a
    # resposta que precisamos: nada chegou daquele sistema ainda.
    try:
        arquivos_na_pasta = {item.name: item for item in dbutils.fs.ls(f"{CAMINHO_RAW}/{sistema}")}
    except Exception:
        arquivos_na_pasta = {}

    for tabela in tabelas:
        nome_arquivo = f"{tabela}.csv"
        info = arquivos_na_pasta.get(nome_arquivo)

        if info is None:
            arquivos_faltando.append(f"{sistema}/{nome_arquivo}")
            continue

        if info.size == 0:
            arquivos_vazios.append(f"{sistema}/{nome_arquivo}")

        # Linha de dado = total de linhas do arquivo menos o cabeçalho.
        total_linhas = spark.read.text(f"{CAMINHO_RAW}/{sistema}/{nome_arquivo}").count() - 1
        registros.append((sistema, nome_arquivo, int(info.size), int(total_linhas)))

# COMMAND ----------

# Grava a tabela de controle: o carimbo de que o dado chegou, com o que
# precisa para auditar depois se algo der errado mais adiante no pipeline.
tabela_controle = (
    spark.createDataFrame(registros, "sistema string, arquivo string, bytes long, linhas long")
    .withColumn("conferido_em", F.current_timestamp())
)

tabela_controle.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(
    f"{catalog}.bronze._raw_arquivos"
)

spark.sql(f"""
    COMMENT ON TABLE {catalog}.bronze._raw_arquivos IS
    'Controle de chegada do raw: um registro por arquivo recebido no Volume bronze.raw,
    com tamanho em bytes, contagem de linhas e horário da conferência. Escrita pela
    tarefa raw_conferencia, sempre no início do pipeline.'
""")

# COMMAND ----------

print(f"{'sistema':<8} {'arquivo':<22} {'bytes':>12} {'linhas':>10}")
print("-" * 56)
for sistema, arquivo, bytes_, linhas in sorted(registros, key=lambda r: (r[0], r[1])):
    print(f"{sistema:<8} {arquivo:<22} {bytes_:>12,} {linhas:>10,}")
print("-" * 56)
print(f"{'TOTAL':<31} {sum(r[2] for r in registros):>12,} {sum(r[3] for r in registros):>10,}")

# COMMAND ----------

# O motivo de a tarefa existir: interromper o pipeline aqui, cedo e barato, em
# vez de deixar a bronze ingerir meio dado com cara de dado inteiro.
if arquivos_faltando:
    raise Exception(f"Arquivos que não chegaram no Volume: {', '.join(arquivos_faltando)}")
if arquivos_vazios:
    raise Exception(f"Arquivos que chegaram vazios (0 bytes): {', '.join(arquivos_vazios)}")

print(f"\nOK — os 10 arquivos chegaram em {CAMINHO_RAW}")
