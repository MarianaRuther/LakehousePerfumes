# Databricks notebook source
# MAGIC %md
# MAGIC # ML · o modelo
# MAGIC
# MAGIC A ordem deste notebook é a ordem que importa, e ela começa antes do `.fit()`:
# MAGIC
# MAGIC 1. **o baseline** — quanto valem as regras que a empresa já usa de graça
# MAGIC 2. o treino, três linhas
# MAGIC 3. as duas métricas: `auc` para quem treina, `lift_top200` para a reunião
# MAGIC 4. importância por permutação
# MAGIC 5. MLflow + Unity Catalog
# MAGIC 6. três testes que interrompem a tarefa
# MAGIC 7. o score — `gold.score_propensao`
# MAGIC 8. as métricas também viram tabela

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_rotaperfume")
catalog = dbutils.widgets.get("catalog")

MODELO = f"{catalog}.gold.propensao_compra"
ALVO = "comprou_em_7d"
SEMENTE = 42

# Quantas ligações o time faz por semana — o tamanho da fila, e o motivo de
# lift_top200 ser a métrica desta operação e não de outra.
TOP_N = 200

# COMMAND ----------

import mlflow
import mlflow.sklearn
import numpy as np
import pandas as pd
from databricks.sdk import WorkspaceClient
from mlflow.tracking import MlflowClient
from pyspark.sql import functions as F
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.inspection import permutation_importance
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import StratifiedKFold, train_test_split

# .astype(float) por garantia: a gold usa DECIMAL(18,2) e o registro do
# modelo morre com "Object of type Decimal is not JSON serializable".
dados = spark.table(f"{catalog}.gold.features_treino").toPandas()
FEATURES = [c for c in dados.columns if c not in ("cliente_id", ALVO, "_referencia")]

X = dados[FEATURES].astype(float)
y = dados[ALVO].astype(int)

X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.25, stratify=y, random_state=SEMENTE)

taxa_base = float(y.mean())
print(f"{len(dados)} clientes × {len(FEATURES)} features")
print(f"taxa base: {100 * taxa_base:.2f}%")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1 · O baseline, antes de treinar qualquer coisa
# MAGIC
# MAGIC As três regras que um gerente comercial defenderia numa reunião, medidas
# MAGIC na mesma régua do modelo: `roc_auc_score` no holdout, usando a coluna crua
# MAGIC como se fosse o score. `-recencia_dias` porque "comprou há pouco" precisa
# MAGIC virar "score alto" para a régua fazer sentido.

# COMMAND ----------


def auc_da_regra(coluna: str, sinal: int = 1) -> float:
    """AUC de uma coluna crua usada como score. roc_auc_score não aceita NaN —
    preenche com a mediana do holdout, o que mantém a comparação justa."""
    valores = X_te[coluna].fillna(X_te[coluna].median())
    return roc_auc_score(y_te, sinal * valores)


baselines = {
    "-recencia_dias (comprou recentemente)": auc_da_regra("recencia_dias", -1),
    "valor_total (compra mais)": auc_da_regra("valor_total"),
    "atraso_relativo (está atrasado)": auc_da_regra("atraso_relativo"),
}

print("regra                                     auc")
for regra, valor in sorted(baselines.items(), key=lambda kv: kv[1]):
    print(f"{regra:<42} {valor:.4f}")
print(f"{'moeda (referência)':<42} 0.5000")

melhor_baseline = max(baselines.values())

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2 · O treino
# MAGIC
# MAGIC `HistGradientBoostingClassifier`, não XGBoost: XGBoost treina e registra,
# MAGIC mas falha ao carregar de volta no serverless (`__sklearn_tags__`, conflito
# MAGIC com scikit-learn 1.6.1) — e o erro só aparece uma tarefa depois. Nada de
# MAGIC imputar NULL: esta árvore trata `NaN` nativamente, e as features de ritmo
# MAGIC são nulas de propósito para quem tem um pedido só.

# COMMAND ----------

modelo = HistGradientBoostingClassifier(random_state=SEMENTE)
modelo.fit(X_tr, y_tr)

auc = float(roc_auc_score(y_te, modelo.predict_proba(X_te)[:, 1]))
print(f"AUC do modelo: {auc:.4f}   (melhor baseline: {melhor_baseline:.4f})")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3 · `lift_top200` — a métrica que responde o diretor
# MAGIC
# MAGIC AUC é métrica de quem treina. A pergunta que paga o projeto é "dos 200 que
# MAGIC eu ligar, quantos compram?". O score sai por validação cruzada
# MAGIC **out-of-fold** sobre a base inteira, não só o holdout: a fila real é 200
# MAGIC entre milhares, e no holdout os 200 primeiros seriam uma fatia grande
# MAGIC demais da amostra — o número sairia otimista.

# COMMAND ----------

oof = np.zeros(len(y), dtype=float)
for treino_idx, teste_idx in StratifiedKFold(5, shuffle=True, random_state=SEMENTE).split(X, y):
    m = HistGradientBoostingClassifier(random_state=SEMENTE)
    m.fit(X.iloc[treino_idx], y.iloc[treino_idx])
    oof[teste_idx] = m.predict_proba(X.iloc[teste_idx])[:, 1]

topo = np.argsort(-oof)[:TOP_N]
acertos_top200 = int(y.iloc[topo].sum())
lift_top200 = float(y.iloc[topo].mean() / taxa_base)

print(f"dos {TOP_N} de maior score, {acertos_top200} compraram na semana seguinte")
print(f"às cegas seriam {round(TOP_N * taxa_base)}  ·  lift: {lift_top200:.2f}×")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4 · Importância por permutação
# MAGIC
# MAGIC Embaralha uma coluna por vez, no holdout, e mede quanto o AUC piora — é
# MAGIC medida, não o `feature_importances_` que a biblioteca chuta.

# COMMAND ----------

perm = permutation_importance(modelo, X_te, y_te, scoring="roc_auc", n_repeats=5, random_state=SEMENTE)

importancia = (
    pd.DataFrame({"feature": FEATURES, "peso": perm.importances_mean})
    .sort_values("peso", ascending=False)
    .reset_index(drop=True)
)
print(importancia.head(10).to_string(index=False))

feature_top = importancia.iloc[0]["feature"]

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5 · MLflow e Unity Catalog
# MAGIC
# MAGIC `set_experiment` não cria a pasta pai — o erro é
# MAGIC `BAD_REQUEST: For input string: "None"` e não menciona pasta nenhuma, por
# MAGIC isso o `mkdirs` vem antes. O serverless traz MLflow 2.22:
# MAGIC `log_model(..., artifact_path=...)`, nunca o `name=` do MLflow 3.

# COMMAND ----------

usuario = WorkspaceClient().current_user.me().user_name
pasta_experimento = f"/Users/{usuario}/rotaperfume_meu_ensaio"
WorkspaceClient().workspace.mkdirs(pasta_experimento)

mlflow.set_registry_uri("databricks-uc")
mlflow.set_experiment(f"{pasta_experimento}/propensao_compra")

with mlflow.start_run(run_name="propensao_compra") as run:
    mlflow.log_params(
        {
            "algoritmo": "HistGradientBoostingClassifier",
            "random_state": SEMENTE,
            "corte_treino": str(dados["_referencia"].iloc[0]),
            "janela_dias": 7,
            "features": len(FEATURES),
            "linhas_treino": len(X_tr),
        }
    )
    mlflow.log_metrics(
        {
            "auc": auc,
            "lift_top200": lift_top200,
            "acertos_top200": acertos_top200,
            "taxa_base": taxa_base,
            "baseline_recencia": baselines["-recencia_dias (comprou recentemente)"],
            "baseline_valor_total": baselines["valor_total (compra mais)"],
            "baseline_atraso": baselines["atraso_relativo (está atrasado)"],
        }
    )
    info = mlflow.sklearn.log_model(
        modelo,
        artifact_path="modelo",
        registered_model_name=MODELO,
        input_example=X_tr.head(3),
    )

versao = info.registered_model_version
MlflowClient(registry_uri="databricks-uc").set_registered_model_alias(MODELO, "prod", versao)
print(f"{MODELO} versão {versao}, alias @prod")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6 · Os três testes que interrompem a tarefa
# MAGIC
# MAGIC Um dado errado quebra sozinho. Um modelo ruim **funciona**: devolve nota
# MAGIC para todo mundo, sem erro nenhum. Por isso ele entra nos mesmos testes que
# MAGIC o dado — vazamento chega com elogio, não com erro.

# COMMAND ----------

assert auc > melhor_baseline + 0.05, (
    f"o modelo (AUC {auc:.4f}) não ganha da melhor regra simples ({melhor_baseline:.4f}) "
    "por margem suficiente. Sem isso, o projeto não se paga."
)
assert auc < 0.99, (
    f"AUC de {auc:.4f} é bom demais para propensão de compra — não é competência, é "
    "vazamento: alguma feature enxergou o que houve depois do corte."
)
assert lift_top200 >= 2.5, (
    f"lift_top200 de {lift_top200:.2f}× é baixo demais para justificar a fila de 200 "
    "ligações — o vendedor faria quase o mesmo ligando no chute."
)
print("os três testes passaram")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 7 · O score
# MAGIC
# MAGIC `mlflow.pyfunc.spark_udf` não roda no serverless
# MAGIC (`InvalidVersion: '18.x-aarch64-photon-scala2'`) — a saída é `load_model` +
# MAGIC pandas, e para poucos milhares de clientes essa é a escolha certa de
# MAGIC qualquer forma. `predict_proba`, nunca `predict`: `predict` devolve a
# MAGIC classe e a coluna inteira viraria zero e um.

# COMMAND ----------

carregado = mlflow.sklearn.load_model(f"models:/{MODELO}@prod")

atual = spark.table(f"{catalog}.gold.features_cliente").toPandas()
# As colunas do treino, na ordem do treino — nunca a ordem da tabela.
X_atual = atual[list(carregado.feature_names_in_)].astype(float)

score = pd.DataFrame(
    {
        "cliente_id": atual["cliente_id"].astype("int32"),
        "score": carregado.predict_proba(X_atual)[:, 1],
        "_referencia": atual["_referencia"],
    }
)
# rank(method="first") antes do qcut evita erro de "bin edges duplicados"
# quando muitos clientes empatam no mesmo score.
score["faixa"] = pd.qcut(
    score["score"].rank(method="first"), 4, labels=["Fria", "Morna", "Quente", "Muito quente"]
).astype(str)
score["versao"] = int(versao)

spark.createDataFrame(score).write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(
    f"{catalog}.gold.score_propensao"
)

spark.sql(f"""
COMMENT ON TABLE {catalog}.gold.score_propensao IS
'Propensão de compra na semana seguinte, por cliente, com a faixa em quartis e a
 versão do modelo que gerou a nota. É desta tabela que sai a fila semanal.'
""")
COMENTARIOS_SCORE = {
    "cliente_id": "Identificador do cliente. Liga com gold.dim_cliente e gold.features_cliente.",
    "score": "Probabilidade prevista de o cliente comprar nos próximos 7 dias (predict_proba da classe positiva).",
    "faixa": "Quartil do score entre os clientes pontuados: Fria, Morna, Quente, Muito quente, do menor para o maior score.",
    "_referencia": "Data de corte das features usadas para pontuar (2026-08-31, o \"hoje\" do dataset).",
    "versao": "Versão do modelo lakehouse_rotaperfume.gold.propensao_compra registrada no Unity Catalog que gerou este score.",
}
for coluna, comentario in COMENTARIOS_SCORE.items():
    spark.sql(f"ALTER TABLE {catalog}.gold.score_propensao ALTER COLUMN {coluna} COMMENT '{comentario}'")

print(f"score_propensao: {len(score)} clientes · {(score.faixa == 'Muito quente').sum()} muito quentes")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 8 · As métricas também viram tabela
# MAGIC
# MAGIC O Genie não lê MLflow, e daqui a seis meses ninguém abre a interface de
# MAGIC experimento — o que precisa ser consultável tem que estar na gold.

# COMMAND ----------

metricas = spark.createDataFrame(
    pd.DataFrame(
        [
            {
                "versao": int(versao),
                "auc": auc,
                "lift_top200": lift_top200,
                "acertos_top200": acertos_top200,
                "taxa_base": taxa_base,
                "baseline_recencia": baselines["-recencia_dias (comprou recentemente)"],
                "baseline_valor_total": baselines["valor_total (compra mais)"],
                "baseline_atraso": baselines["atraso_relativo (está atrasado)"],
                "feature_mais_importante": feature_top,
            }
        ]
    )
).withColumn("_treinado_em", F.current_timestamp())

metricas.write.mode("append").option("mergeSchema", "true").saveAsTable(f"{catalog}.gold.modelo_metricas")

spark.sql(f"""
COMMENT ON TABLE {catalog}.gold.modelo_metricas IS
'Uma linha por treino do modelo de propensão: AUC, lift_top200, acertos entre os
 200 primeiros, taxa base e o AUC de cada regra simples. Histórico de "o modelo
 está melhor ou pior que o treino anterior" sem abrir o MLflow.'
""")
COMENTARIOS_METRICAS = {
    "versao": "Versão do modelo no Unity Catalog (lakehouse_rotaperfume.gold.propensao_compra) que gerou esta linha.",
    "auc": "Area under the ROC curve do modelo, medida no holdout (25% de gold.features_treino, nunca visto no treino).",
    "lift_top200": "Taxa de compra dos 200 clientes de maior score (out-of-fold) dividida pela taxa base — quantas vezes o modelo é melhor que ligar às cegas.",
    "acertos_top200": "Quantos dos 200 clientes de maior score (out-of-fold) compraram na janela de 7 dias.",
    "taxa_base": "Fração de clientes de gold.features_treino que compraram na janela de 7 dias — a taxa de acerto de uma fila sorteada.",
    "baseline_recencia": "AUC no holdout da regra \"ligar para quem comprou recentemente\" (-recencia_dias como score).",
    "baseline_valor_total": "AUC no holdout da regra \"ligar para quem compra mais\" (valor_total como score).",
    "baseline_atraso": "AUC no holdout da regra \"ligar para quem está atrasado\" (atraso_relativo como score).",
    "feature_mais_importante": "Feature com maior importância por permutação (queda de AUC ao embaralhar a coluna) no holdout.",
    "_treinado_em": "Momento em que este treino rodou.",
}
for coluna, comentario in COMENTARIOS_METRICAS.items():
    spark.sql(f"ALTER TABLE {catalog}.gold.modelo_metricas ALTER COLUMN {coluna} COMMENT '{comentario}'")

# A calibragem sai do HOLDOUT, que tem o rótulo verdadeiro — é a prova que o
# comercial confere sozinho, sem ouvir a palavra AUC.
holdout = pd.DataFrame({"score": modelo.predict_proba(X_te)[:, 1], "comprou": y_te.values})
holdout["faixa"] = pd.qcut(
    holdout["score"].rank(method="first"), 4, labels=["Fria", "Morna", "Quente", "Muito quente"]
).astype(str)

calibragem = holdout.groupby("faixa", as_index=False).agg(
    clientes=("comprou", "size"),
    compraram=("comprou", "sum"),
    taxa_de_compra=("comprou", "mean"),
    score_medio=("score", "mean"),
)

spark.createDataFrame(calibragem).write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(
    f"{catalog}.gold.calibragem_holdout"
)

spark.sql(f"""
COMMENT ON TABLE {catalog}.gold.calibragem_holdout IS
'Taxa de compra por faixa de score, medida nos clientes do holdout — que o modelo
 NÃO viu no treino. Se a taxa sobe de Fria para Muito quente, o score ordena, e
 isso se confere sem saber o que é curva ROC.'
""")
COMENTARIOS_CALIBRAGEM = {
    "faixa": "Quartil do score dos clientes do holdout: Fria, Morna, Quente, Muito quente, do menor para o maior score.",
    "clientes": "Quantidade de clientes do holdout nesta faixa.",
    "compraram": "Quantos desses clientes compraram de fato na janela de 7 dias (comprou_em_7d = 1).",
    "taxa_de_compra": "compraram dividido por clientes — deve subir de Fria para Muito quente se o score ordena bem.",
    "score_medio": "Média do score previsto pelo modelo para os clientes desta faixa.",
}
for coluna, comentario in COMENTARIOS_CALIBRAGEM.items():
    spark.sql(f"ALTER TABLE {catalog}.gold.calibragem_holdout ALTER COLUMN {coluna} COMMENT '{comentario}'")

print(calibragem.to_string(index=False))
