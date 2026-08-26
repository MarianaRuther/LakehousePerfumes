-- Gold · auditoria de metadado
--
-- Metadado faltando é BUG, não pendência de documentação.
--
-- O Genie não lê o nome de uma coluna e adivinha o que ela significa — ele lê
-- o COMMENT e decide onde procurar e como calcular. Uma view sem COMMENT é
-- uma view que o Genie ignora; uma coluna `margem` sem COMMENT é uma coluna
-- que o Genie soma sem saber se ali entra frete ou não.
--
-- Por isso esta auditoria roda dentro do pipeline, quebra igual aos 9 testes
-- do prompt anterior, e — só depois de garantir que não falta nada — imprime
-- um relatório de cobertura para a conversa com quem vai consumir a gold.

-- ── 1 · Toda tabela e toda view da gold tem COMMENT ────────────────────
SELECT '1 · tabelas e views da gold com COMMENT' AS teste,
       CAST(sem_comentario AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN sem_comentario = 0 THEN 'PASSOU'
            ELSE raise_error(concat(sem_comentario, ' objetos da gold sem COMMENT: ', objetos))
       END AS resultado
FROM (
  SELECT
    count(*) AS sem_comentario,
    concat_ws(', ', collect_list(table_name)) AS objetos
  FROM lakehouse_rotaperfume.information_schema.tables
  WHERE table_schema = 'gold' AND (comment IS NULL OR trim(comment) = '')
);

-- ── 2 · Toda coluna de fato_vendas e das 6 views de negócio tem COMMENT ─
-- As dimensões podem ter coluna autoexplicativa (cidade, uf). fato_vendas e
-- as views de negócio são o que o Genie lê primeiro — nelas a cobertura é
-- total, sem exceção.
SELECT '2 · colunas de fato_vendas e das views de negócio com COMMENT' AS teste,
       CAST(sem_comentario AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN sem_comentario = 0 THEN 'PASSOU'
            ELSE raise_error(concat(sem_comentario, ' colunas sem COMMENT: ', colunas))
       END AS resultado
FROM (
  SELECT
    count(*) AS sem_comentario,
    concat_ws(', ', collect_list(concat(table_name, '.', column_name))) AS colunas
  FROM lakehouse_rotaperfume.information_schema.columns
  WHERE table_schema = 'gold'
    AND table_name IN ('fato_vendas', 'receita_mensal', 'ranking_marcas',
                        'margem_por_categoria', 'clientes_em_risco',
                        'efeito_lancamento', 'ruptura_por_marca')
    AND (comment IS NULL OR trim(comment) = '')
);

-- ── O relatório: quanto da gold está documentada, por objeto ───────────
-- Não quebra nada — serve para mostrar na conversa com quem vai consumir.
SELECT
  table_name AS objeto,
  count(*) AS colunas,
  sum(CASE WHEN comment IS NOT NULL AND trim(comment) <> '' THEN 1 ELSE 0 END) AS colunas_comentadas,
  round(avg(CASE WHEN comment IS NOT NULL AND trim(comment) <> '' THEN 1.0 ELSE 0.0 END), 2) AS cobertura
FROM lakehouse_rotaperfume.information_schema.columns
WHERE table_schema = 'gold'
GROUP BY table_name
ORDER BY cobertura, table_name;
