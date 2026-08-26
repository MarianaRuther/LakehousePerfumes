# Databricks notebook source
# MAGIC %md
# MAGIC # ML · features
# MAGIC
# MAGIC A primeira camada de ML do projeto: uma função só, `montar_features(referencia)`,
# MAGIC que devolve uma linha por cliente com **tudo que se sabia dele até essa data** — nem
# MAGIC um dia depois.
# MAGIC
# MAGIC Vinte features em quatro grupos, todas derivadas de `gold.fato_vendas`,
# MAGIC `silver.oportunidades` e `silver.visitas`, cada fonte cortada pela própria data
# MAGIC (`data_pedido`, `data_abertura`, `data_visita`) com `<`, nunca `<=` — o dia da
# MAGIC referência ainda não aconteceu para quem está sendo pontuado.
# MAGIC
# MAGIC **`gold.dim_cliente` não entra em feature nenhuma.** Ela guarda
# MAGIC `dias_sem_comprar`, `receita_acumulada` e `total_pedidos` calculados sobre a base
# MAGIC INTEIRA, sem corte — usar qualquer uma delas aqui seria vazar o futuro para dentro
# MAGIC do treino. Ela só volta a aparecer no próximo prompt, para nome e cidade.
# MAGIC
# MAGIC A mesma função roda duas vezes:
# MAGIC
# MAGIC | Tabela | Referência | Alvo |
# MAGIC |---|---|---|
# MAGIC | `gold.features_treino`  | 2026-08-01 | `comprou_em_7d` (pedido entre 01 e 07/08/2026) |
# MAGIC | `gold.features_cliente` | 2026-08-31 (o "hoje" do dataset) | nenhum — é o que o modelo pontua |

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_rotaperfume")
catalog = dbutils.widgets.get("catalog")

# COMMAND ----------

from pyspark.sql import functions as F
from pyspark.sql.window import Window


def montar_features(referencia: str):
    """Uma linha por cliente com o que se sabia dele até `referencia` ('AAAA-MM-DD').

    A base é o cliente que já tem pedido até a referência — sem pedido não há RFM
    para calcular. CRM e mix são LEFT JOIN por cima: cliente sem oportunidade, sem
    visita, sem marca dominante ou sem lançamento comprado fica com 0, nunca NULL.
    Só o grupo de ritmo (intervalo, desvio, atraso) pode ficar NULL de verdade —
    quando o cliente tem um único pedido, não existe intervalo entre pedidos para medir.
    """
    referencia_data = F.to_date(F.lit(referencia))
    corte_90d = F.date_sub(referencia_data, 90)
    corte_120d = F.date_sub(referencia_data, 120)

    # cada fonte, cortada pela própria data — sem exceção
    fato = spark.table(f"{catalog}.gold.fato_vendas").where(F.col("data_pedido") < referencia)
    oportunidades = spark.table(f"{catalog}.silver.oportunidades").where(F.col("data_abertura") < referencia)
    visitas = spark.table(f"{catalog}.silver.visitas").where(F.col("data_visita") < referencia)
    produtos = spark.table(f"{catalog}.gold.dim_produto")

    # ---------- mix: marca com maior receita por cliente ----------
    marca_top = (
        fato.groupBy("cliente_id", "marca")
        .agg(F.sum(F.col("receita").cast("double")).alias("receita_marca"))
        .withColumn(
            "_rn",
            F.row_number().over(Window.partitionBy("cliente_id").orderBy(F.col("receita_marca").desc())),
        )
        .where("_rn = 1")
        .select("cliente_id", F.col("receita_marca").alias("_receita_marca_top"))
    )

    # ---------- mix: comprou algum SKU lançado nos 120 dias antes do corte ----------
    lancamento = (
        fato.join(produtos.select("sku", "data_lancamento"), "sku")
        .where((F.col("data_lancamento") >= corte_120d) & (F.col("data_lancamento") < referencia_data))
        .select("cliente_id")
        .distinct()
        .withColumn("comprou_lancamento", F.lit(1))
    )

    # ---------- ritmo: intervalo entre pedidos CONSECUTIVOS do mesmo cliente ----------
    # uma linha por data de pedido distinta — dois pedidos no mesmo dia não geram intervalo.
    janela_cliente = Window.partitionBy("cliente_id").orderBy("data_pedido")
    intervalos = (
        fato.select("cliente_id", "data_pedido")
        .distinct()
        .withColumn("_data_anterior", F.lag("data_pedido").over(janela_cliente))
        .withColumn("_intervalo", F.datediff(F.col("data_pedido"), F.col("_data_anterior")))
    )
    ritmo = intervalos.groupBy("cliente_id").agg(
        F.stddev(F.col("_intervalo").cast("double")).alias("desvio_intervalo_dias")
    )

    # ---------- RFM + o resto do mix, numa passada só sobre o fato filtrado ----------
    rfm_mix = fato.groupBy("cliente_id").agg(
        F.datediff(referencia_data, F.max("data_pedido")).alias("recencia_dias"),
        F.countDistinct("pedido_id").alias("frequencia_pedidos"),
        F.sum(F.col("receita").cast("double")).alias("valor_total"),
        F.sum(F.col("margem").cast("double")).alias("margem_total"),
        F.min("data_pedido").alias("_data_min"),
        F.max("data_pedido").alias("_data_max"),
        # collect_set ignora NULL sozinho — é o jeito limpo de contar distinct condicional
        F.size(F.collect_set(F.when(F.col("data_pedido") >= corte_90d, F.col("pedido_id")))).alias(
            "pedidos_ultimos_90d"
        ),
        F.countDistinct("sku").alias("skus_distintos"),
        F.countDistinct("categoria").alias("categorias_distintas"),
        F.countDistinct("marca").alias("marcas_distintas"),
    )

    rfm_mix = (
        rfm_mix.withColumn(
            "intervalo_medio_dias",
            F.expr("datediff(_data_max, _data_min) / nullif(frequencia_pedidos - 1, 0)"),
        )
        .withColumn("ticket_medio", F.expr("valor_total / nullif(frequencia_pedidos, 0)"))
        .withColumn("margem_percentual", F.expr("margem_total / nullif(valor_total, 0)"))
        .drop("_data_min", "_data_max")
    )

    # ---------- CRM: oportunidades e visitas, cada uma com o próprio total ----------
    crm_oportunidades = (
        oportunidades.groupBy("cliente_id")
        .agg(
            F.sum(F.when(~F.col("ganha") & ~F.col("perdida"), 1).otherwise(0)).alias("oportunidades_abertas"),
            F.sum(F.when(F.col("ganha"), 1).otherwise(0)).alias("oportunidades_ganhas"),
            F.count(F.lit(1)).alias("_total_oportunidades"),
        )
        .withColumn("taxa_ganho", F.expr("oportunidades_ganhas / nullif(_total_oportunidades, 0)"))
        .select("cliente_id", "oportunidades_abertas", "oportunidades_ganhas", "taxa_ganho")
    )

    crm_visitas = (
        visitas.groupBy("cliente_id")
        .agg(
            F.sum(F.when(F.col("data_visita") >= corte_90d, 1).otherwise(0)).alias("visitas_90d"),
            F.sum(F.when(F.col("resultado") == "Pedido realizado", 1).otherwise(0)).alias("_visitas_com_pedido"),
            F.count(F.lit(1)).alias("_total_visitas"),
        )
        .withColumn("conversao_visita", F.expr("_visitas_com_pedido / nullif(_total_visitas, 0)"))
        .select("cliente_id", "visitas_90d", "conversao_visita")
    )

    # ---------- monta a linha final: base = cliente com pedido, resto por LEFT JOIN ----------
    df = (
        rfm_mix.join(ritmo, "cliente_id", "left")
        .join(crm_oportunidades, "cliente_id", "left")
        .join(crm_visitas, "cliente_id", "left")
        .join(marca_top, "cliente_id", "left")
        .join(lancamento, "cliente_id", "left")
    )

    # atraso_relativo: CUIDADO — F.least ignora NULL, então o teto de 10 só pode
    # entrar dentro do ramo THEN do CASE, nunca por fora dele.
    df = df.withColumn(
        "atraso_relativo",
        F.when(
            F.col("intervalo_medio_dias").isNotNull() & (F.col("intervalo_medio_dias") > 0),
            F.least(F.col("recencia_dias") / F.col("intervalo_medio_dias"), F.lit(10.0)),
        ),
    )

    df = df.withColumn("concentracao_marca_top", F.expr("_receita_marca_top / nullif(valor_total, 0)"))

    # cliente sem oportunidade, sem visita, sem marca-top calculável ou sem
    # lançamento comprado fica com 0 — só o grupo de ritmo pode ser NULL de verdade.
    for c in (
        "oportunidades_abertas",
        "oportunidades_ganhas",
        "taxa_ganho",
        "visitas_90d",
        "conversao_visita",
        "concentracao_marca_top",
        "comprou_lancamento",
    ):
        df = df.withColumn(c, F.coalesce(F.col(c), F.lit(0.0)))

    df = (
        df.withColumn("oportunidades_abertas", F.col("oportunidades_abertas").cast("int"))
        .withColumn("oportunidades_ganhas", F.col("oportunidades_ganhas").cast("int"))
        .withColumn("visitas_90d", F.col("visitas_90d").cast("int"))
        .withColumn("comprou_lancamento", F.col("comprou_lancamento").cast("int"))
        .withColumn("_referencia", referencia_data)
    )

    return df.select(
        "cliente_id",
        # RFM
        "recencia_dias",
        "frequencia_pedidos",
        "valor_total",
        "ticket_medio",
        "margem_total",
        "margem_percentual",
        # Ritmo
        "intervalo_medio_dias",
        "desvio_intervalo_dias",
        "atraso_relativo",
        "pedidos_ultimos_90d",
        # CRM
        "oportunidades_abertas",
        "oportunidades_ganhas",
        "taxa_ganho",
        "visitas_90d",
        "conversao_visita",
        # Mix
        "skus_distintos",
        "categorias_distintas",
        "marcas_distintas",
        "concentracao_marca_top",
        "comprou_lancamento",
        "_referencia",
    )

# COMMAND ----------

# Comentários de coluna compartilhados pelas duas tabelas — o texto que o Genie e
# quem herdar este projeto leem para saber o que cada número significa.
COMENTARIOS_FEATURES = {
    "cliente_id": "Identificador do cliente. Liga com gold.dim_cliente — usada só para nome e cidade, nunca para feature.",
    "recencia_dias": "Dias entre o último pedido do cliente e a data de corte (_referencia). Quanto maior, mais tempo sem comprar.",
    "frequencia_pedidos": "Quantidade de pedidos distintos do cliente até a data de corte.",
    "valor_total": "Soma da receita de todos os pedidos do cliente até a data de corte, incluindo devolução (receita negativa) — a mesma regra de gold.fato_vendas.",
    "ticket_medio": "valor_total dividido por frequencia_pedidos.",
    "margem_total": "Soma da margem de todos os pedidos do cliente até a data de corte.",
    "margem_percentual": "margem_total dividido por valor_total. NULL quando valor_total é zero.",
    "intervalo_medio_dias": "Média de dias entre pedidos consecutivos do cliente: (último pedido − primeiro pedido) / (pedidos distintos − 1). NULL quando o cliente tem um único pedido.",
    "desvio_intervalo_dias": "Desvio padrão dos intervalos entre pedidos consecutivos do cliente. NULL quando o cliente tem um único pedido — não há intervalo para medir variação.",
    "atraso_relativo": "recencia_dias dividido por intervalo_medio_dias, com teto em 10 — acima disso o cliente já está claramente fora do próprio ritmo. NULL quando intervalo_medio_dias é NULL.",
    "pedidos_ultimos_90d": "Pedidos distintos do cliente nos 90 dias antes da data de corte.",
    "oportunidades_abertas": "Oportunidades do cliente no CRM ainda não fechadas (nem ganhas, nem perdidas) até a data de corte. Zero quando o cliente não tem oportunidade.",
    "oportunidades_ganhas": "Oportunidades do cliente marcadas como ganhas até a data de corte. Zero quando o cliente não tem oportunidade.",
    "taxa_ganho": "oportunidades_ganhas dividido pelo total de oportunidades do cliente. Zero quando o cliente não tem oportunidade.",
    "visitas_90d": 'Visitas do vendedor ao cliente nos 90 dias antes da data de corte. Zero quando o cliente não tem visita.',
    "conversao_visita": 'Proporção das visitas do cliente que resultaram em "Pedido realizado". Zero quando o cliente não tem visita.',
    "skus_distintos": "Quantidade de SKUs distintos comprados pelo cliente até a data de corte.",
    "categorias_distintas": "Quantidade de categorias de produto distintas compradas pelo cliente até a data de corte.",
    "marcas_distintas": "Quantidade de marcas distintas compradas pelo cliente até a data de corte.",
    "concentracao_marca_top": "Receita da marca mais comprada pelo cliente dividida pela receita total — quão dependente o cliente é de uma única marca.",
    "comprou_lancamento": "1 se o cliente comprou algum SKU lançado (gold.dim_produto.data_lancamento) nos 120 dias antes da data de corte, senão 0.",
    "_referencia": "Data de corte usada para calcular estas features — nenhuma fonte usa dado igual ou posterior a ela.",
}


def gravar_com_comentario(df, tabela: str, comentario_tabela: str, comentarios_coluna: dict):
    """Grava a tabela e aplica COMMENT em português na tabela e em cada coluna."""
    destino = f"{catalog}.gold.{tabela}"
    df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(destino)
    spark.sql(f"COMMENT ON TABLE {destino} IS '{comentario_tabela}'")
    for coluna, comentario in comentarios_coluna.items():
        spark.sql(f"ALTER TABLE {destino} ALTER COLUMN {coluna} COMMENT '{comentario}'")
    return spark.table(destino).count()

# COMMAND ----------

# gold.features_treino — corte em 2026-08-01, com o alvo do modelo.
#
# comprou_em_7d olha PARA FRENTE de propósito: é a mesma janela de 7 dias da fila
# de ligação semanal. Com 30 dias a taxa base sobe de 10,1% para 39,9% e o ganho
# do modelo deixa de fazer sentido para o comercial — por isso a janela é curta.
REFERENCIA_TREINO = "2026-08-01"

features_treino = montar_features(REFERENCIA_TREINO)

alvo = (
    spark.table(f"{catalog}.gold.fato_vendas")
    .where((F.col("data_pedido") >= "2026-08-01") & (F.col("data_pedido") <= "2026-08-07"))
    .select("cliente_id")
    .distinct()
    .withColumn("comprou_em_7d", F.lit(1))
)

features_treino = features_treino.join(alvo, "cliente_id", "left").withColumn(
    "comprou_em_7d", F.coalesce(F.col("comprou_em_7d"), F.lit(0)).cast("int")
)

comentarios_treino = dict(COMENTARIOS_FEATURES)
comentarios_treino["comprou_em_7d"] = (
    "Alvo do treino: 1 se o cliente fez pedido entre 2026-08-01 e 2026-08-07 "
    "(a mesma semana da fila de ligação), senão 0."
)

linhas_treino = gravar_com_comentario(
    features_treino,
    "features_treino",
    "Uma linha por cliente com 20 features calculadas no corte de 2026-08-01 (nada visto a partir dessa "
    "data) e o alvo comprou_em_7d. Usada para TREINAR o modelo de propensão de compra — nunca para servir.",
    comentarios_treino,
)

# COMMAND ----------

# gold.features_cliente — corte em 2026-08-31, o "hoje" do dataset. Sem alvo: é
# a foto atual que o modelo de propensão vai pontuar para montar a fila semanal.
REFERENCIA_CLIENTE = "2026-08-31"

features_cliente = montar_features(REFERENCIA_CLIENTE)

linhas_cliente = gravar_com_comentario(
    features_cliente,
    "features_cliente",
    "Uma linha por cliente com as mesmas 20 features de gold.features_treino, calculadas no corte de "
    "2026-08-31 (hoje do dataset), sem alvo. É o que o modelo de propensão pontua para gerar a fila semanal.",
    COMENTARIOS_FEATURES,
)

print(f"gold.features_treino  : {linhas_treino:,} clientes (referência {REFERENCIA_TREINO})")
print(f"gold.features_cliente : {linhas_cliente:,} clientes (referência {REFERENCIA_CLIENTE})")
