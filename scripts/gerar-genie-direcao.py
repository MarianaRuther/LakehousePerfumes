"""Gera resources/direcao.geniespace.json de forma determinística.

Rode da raiz do bundle:  python scripts/gerar-genie-direcao.py
Fonte legível das instruções: docs/genie-direcao-instrucoes.md

Regras da API do Genie:
  a) data_sources.tables ordenado por identifier
  b) column_configs de cada tabela ordenado por column_name
  c) todo id = 32 hex minúsculos, sem hífen  -> md5 hexdigest do conteúdo
  d) sample_questions, example_question_sqls e text_instructions ordenados por id
"""
import hashlib
import json
import pathlib

CAT = "lakehouse_rotaperfume.gold"


def mid(*parts: str) -> str:
    return hashlib.md5("\x1e".join(parts).encode("utf-8")).hexdigest()


def col(name: str) -> dict:
    return {
        "column_name": name,
        "enable_format_assistance": True,
        "enable_entity_matching": True,
    }


def table(identifier: str, cols: list[str]) -> dict:
    out = {"identifier": identifier}
    if cols:
        out["column_configs"] = [col(c) for c in sorted(cols)]
    return out


# ── a) + b) — as fontes, ordenadas por identifier; colunas ordenadas ──────
# Começou com sete; gold.calibragem_holdout entrou depois, quando o Genie
# insistiu em calcular a conversão do modelo na mão (score_propensao x
# fato_vendas numa janela de data que ele não tem contexto para escolher) e
# concluiu que o modelo estava "invertido". Ela é a evolução da taxa de compra
# por faixa, medida no holdout — a resposta pronta para "o modelo é bom?".
tables = sorted(
    [
        table(f"{CAT}.calibragem_holdout", ["faixa"]),
        table(f"{CAT}.clientes_em_risco", ["cidade", "razao_social", "segmento"]),
        table(f"{CAT}.fila_semanal", ["cidade", "faixa", "razao_social", "uf", "vendedor"]),
        table(f"{CAT}.modelo_metricas", ["feature_mais_importante"]),
        table(f"{CAT}.ranking_marcas", ["marca"]),
        table(f"{CAT}.receita_mensal", []),
        table(f"{CAT}.retorno_ligacao", ["registrado_por", "status", "vendedor"]),
        table(f"{CAT}.score_propensao", ["faixa"]),
    ],
    key=lambda t: t["identifier"],
)

# ── sample_questions ──────────────────────────────────────────────────────
sample_qs_text = [
    "Quem eu ligo essa semana?",
    "Quanto vale a fila desta semana?",
    "Quantas ligações da fila já foram registradas e quantas viraram pedido?",
    "O modelo de propensão está ganhando de ligar às cegas?",
    "O modelo é bom? Dá para confiar no score?",
    "Quais clientes da fila desta semana já estão em risco de churn?",
]
sample_questions = sorted(
    [{"id": mid(q), "question": [q]} for q in sample_qs_text],
    key=lambda x: x["id"],
)

# ── example_question_sqls — pares pergunta->SQL, todos validados no warehouse
pairs = [
    (
        "Quem eu ligo essa semana?",
        [
            "-- A fila da semana inteira, na ordem de ligação de cada vendedor.\n",
            "SELECT vendedor, ordem, cliente_id, razao_social, cidade, uf,\n",
            "       score, faixa, ticket_medio, motivo, sugestao\n",
            "FROM lakehouse_rotaperfume.gold.fila_semanal\n",
            "ORDER BY vendedor, ordem;\n",
        ],
    ),
    (
        "Quanto vale a fila desta semana?",
        [
            "-- Receita ESPERADA (estimativa), nunca receita realizada:\n",
            "-- soma de score x ticket_medio dos 200 da fila.\n",
            "SELECT ROUND(SUM(score * ticket_medio), 2) AS receita_esperada_estimada,\n",
            "       COUNT(*)                             AS clientes_na_fila,\n",
            "       ROUND(AVG(score), 4)                  AS score_medio\n",
            "FROM lakehouse_rotaperfume.gold.fila_semanal;\n",
        ],
    ),
    (
        "Quantas ligações da fila já foram registradas e quantas viraram pedido?",
        [
            "-- 'Ligacao' aqui e SEMPRE gold.retorno_ligacao. NUNCA silver.visitas\n",
            "-- (visita presencial, outro conceito) nem qualquer tabela de visita.\n",
            "-- retorno_ligacao comeca VAZIA: se vier zero, ninguem registrou retorno\n",
            "-- ainda -- essa e a resposta, nao ir buscar numero em outra tabela.\n",
            "-- Um cliente pode ter mais de um retorno: fica so o mais recente por registrado_em.\n",
            "WITH ultimo AS (\n",
            "  SELECT status,\n",
            "         ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) AS rn\n",
            "  FROM lakehouse_rotaperfume.gold.retorno_ligacao\n",
            ")\n",
            "SELECT COUNT(*)                        AS ligacoes_registradas,\n",
            "       COUNT_IF(status = 'vendeu')    AS viraram_pedido,\n",
            "       ROUND(COUNT_IF(status = 'vendeu') / NULLIF(COUNT(*), 0), 4) AS taxa_conversao\n",
            "FROM ultimo\n",
            "WHERE rn = 1;\n",
        ],
    ),
    (
        "O modelo de propensão está ganhando de ligar às cegas?",
        [
            "-- A metrica da direcao e lift_top200: quantas vezes a fila e melhor que o sorteio.\n",
            "-- NUNCA responder pergunta de negocio com AUC.\n",
            "SELECT versao,\n",
            "       lift_top200,\n",
            "       acertos_top200,\n",
            "       taxa_base,\n",
            "       ROUND(acertos_top200 / 200.0, 4) AS taxa_de_compra_da_fila\n",
            "FROM lakehouse_rotaperfume.gold.modelo_metricas\n",
            "ORDER BY _treinado_em DESC\n",
            "LIMIT 1;\n",
        ],
    ),
    (
        "O modelo é bom? Dá para confiar no score?",
        [
            "-- Desempenho/qualidade/confianca do modelo SEMPRE sai de tabela pronta:\n",
            "-- gold.calibragem_holdout (evolucao da taxa de compra por faixa, medida\n",
            "-- no holdout que o modelo nao viu) e gold.modelo_metricas (lift_top200).\n",
            "-- NUNCA cruzar score_propensao com fato_vendas para calcular conversao na\n",
            "-- mao: isso depende de uma janela de data sem contexto e ja deu conclusao\n",
            "-- falsa de 'modelo invertido'.\n",
            "SELECT c.faixa,\n",
            "       c.clientes,\n",
            "       c.compraram,\n",
            "       ROUND(100 * c.taxa_de_compra, 1) AS pct_que_comprou,\n",
            "       ROUND(c.score_medio, 4)          AS score_medio,\n",
            "       m.lift_top200,\n",
            "       m.acertos_top200,\n",
            "       ROUND(m.taxa_base, 4)            AS taxa_base\n",
            "FROM lakehouse_rotaperfume.gold.calibragem_holdout c\n",
            "CROSS JOIN (\n",
            "  SELECT lift_top200, acertos_top200, taxa_base\n",
            "  FROM lakehouse_rotaperfume.gold.modelo_metricas\n",
            "  ORDER BY _treinado_em DESC\n",
            "  LIMIT 1\n",
            ") m\n",
            "ORDER BY c.score_medio;\n",
        ],
    ),
    (
        "Quais clientes da fila desta semana já estão em risco de churn, e quanta receita mensal está em jogo?",
        [
            "-- clientes_em_risco.cliente_id e STRING; fila_semanal.cliente_id e INT.\n",
            "SELECT f.vendedor, f.ordem, f.razao_social, f.cidade, f.faixa,\n",
            "       r.dias_sem_comprar, r.receita_mensal_media\n",
            "FROM lakehouse_rotaperfume.gold.fila_semanal f\n",
            "JOIN lakehouse_rotaperfume.gold.clientes_em_risco r\n",
            "  ON CAST(r.cliente_id AS INT) = f.cliente_id\n",
            "ORDER BY r.receita_mensal_media DESC;\n",
        ],
    ),
]
example_question_sqls = sorted(
    [{"id": mid(q, "".join(sql)), "question": [q], "sql": sql} for q, sql in pairs],
    key=lambda x: x["id"],
)

# ── text_instructions — um unico item (a API recusa mais de um) ───────────
instr = pathlib.Path("docs/genie-direcao-instrucoes.md").read_text(encoding="utf-8")
# guarda como lista de linhas, cada uma terminando em \n, igual ao comercial
instr_lines = [ln + "\n" for ln in instr.split("\n")]
text_instructions = sorted(
    [{"id": mid("text_instructions", instr), "content": instr_lines}],
    key=lambda x: x["id"],
)

space = {
    "version": 2,
    "data_sources": {"tables": tables},
    "config": {"sample_questions": sample_questions},
    "instructions": {
        "text_instructions": text_instructions,
        "example_question_sqls": example_question_sqls,
    },
}

out = pathlib.Path("resources/direcao.geniespace.json")
out.write_text(json.dumps(space, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"escrito {out} — {len(tables)} tabelas, {len(sample_questions)} sample_questions, "
      f"{len(example_question_sqls)} pares pergunta->SQL")
# checagem das quatro regras
ids = [t["identifier"] for t in tables]
assert ids == sorted(ids), "regra a"
for t in tables:
    cc = [c["column_name"] for c in t.get("column_configs", [])]
    assert cc == sorted(cc), f"regra b: {t['identifier']}"
allids = [x["id"] for x in sample_questions + example_question_sqls + text_instructions]
assert all(len(i) == 32 and all(c in "0123456789abcdef" for c in i) for i in allids), "regra c"
assert len(allids) == len(set(allids)), "regra c: ids duplicados"
for lst in (sample_questions, example_question_sqls, text_instructions):
    got = [x["id"] for x in lst]
    assert got == sorted(got), "regra d"
print("as quatro regras da API: OK")
