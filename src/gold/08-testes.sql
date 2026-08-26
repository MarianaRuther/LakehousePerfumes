-- Gold · os 9 testes de qualidade
--
-- Teste que não quebra o job não é teste, é relatório. Cada bloco aqui imprime
-- o que calculou e, se estiver errado, chama raise_error() — que interrompe a
-- tarefa e derruba o pipeline inteiro.
--
-- É melhor o dashboard ficar com o dado de ONTEM do que com o dado ERRADO de
-- hoje. O primeiro problema alguém percebe; o segundo, não.
--
-- Ordem de importância: o teste 1 é o que mais vale. Limpeza que muda o
-- faturamento é limpeza que jogou dado fora sem querer.

-- ── 1 · A receita atravessou as três camadas sem mudar ────────────────
SELECT '1 · receita gold = receita silver = R$ 102.303.828,05' AS teste,
       CAST(gold AS STRING) AS calculado,
       CAST(silver AS STRING) AS esperado,
       CASE WHEN abs(gold - silver) < 0.01 AND abs(gold - esperado_fixo) < 0.01 THEN 'PASSOU'
            ELSE raise_error(concat(
              'Receita divergiu: gold=', gold, ' silver=', silver, ' esperado=', esperado_fixo))
       END AS resultado
FROM (
  SELECT
    (SELECT SUM(receita)       FROM lakehouse_rotaperfume.gold.fato_vendas) AS gold,
    (SELECT SUM(valor_liquido) FROM lakehouse_rotaperfume.silver.pedidos)   AS silver,
    CAST(102303828.05 AS DECIMAL(18, 2))                                   AS esperado_fixo
);

-- ── 2 · CNPJ único depois da deduplicação ─────────────────────────────
SELECT '2 · CNPJ único na silver.clientes' AS teste,
       CAST(duplicados AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN duplicados = 0 THEN 'PASSOU'
            ELSE raise_error(concat(duplicados, ' CNPJ ainda duplicados na silver'))
       END AS resultado
FROM (SELECT count(*) - count(DISTINCT cnpj) AS duplicados
      FROM lakehouse_rotaperfume.silver.clientes);

-- ── 3 · Nenhuma data perdida na conversão dos dois formatos ───────────
SELECT '3 · nenhuma data_pedido nula' AS teste,
       CAST(nulas AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN nulas = 0 THEN 'PASSOU'
            ELSE raise_error(concat(nulas, ' pedidos ficaram sem data — algum formato novo apareceu na origem'))
       END AS resultado
FROM (SELECT count(*) AS nulas FROM lakehouse_rotaperfume.silver.pedidos WHERE data_pedido IS NULL);

-- ── 4 · Receita negativa só onde é devolução ──────────────────────────
SELECT '4 · receita negativa só em devolução' AS teste,
       CAST(fora AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN fora = 0 THEN 'PASSOU'
            ELSE raise_error(concat(fora, ' linhas com receita negativa sem flag de devolução'))
       END AS resultado
FROM (SELECT count(*) AS fora FROM lakehouse_rotaperfume.gold.fato_vendas
      WHERE receita < 0 AND NOT devolucao);

-- ── 5 · Volume dentro da faixa esperada ───────────────────────────────
-- Pega queda silenciosa de ingestão: o pipeline "funciona", ninguém vê erro,
-- e o dashboard mostra metade da receita com cara de número certo.
SELECT '5 · volume da fato_vendas' AS teste,
       CAST(linhas AS STRING) AS calculado, 'entre 140.000 e 250.000' AS esperado,
       CASE WHEN linhas BETWEEN 140000 AND 250000 THEN 'PASSOU'
            ELSE raise_error(concat('fato_vendas com ', linhas, ' linhas, fora da faixa esperada'))
       END AS resultado
FROM (SELECT count(*) AS linhas FROM lakehouse_rotaperfume.gold.fato_vendas);

-- ── 6 · Nenhum pedido órfão ───────────────────────────────────────────
SELECT '6 · nenhum pedido_id órfão no fato' AS teste,
       CAST(orfaos AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN orfaos = 0 THEN 'PASSOU'
            ELSE raise_error(concat(orfaos, ' pedido_id na gold que não existem na silver.pedidos'))
       END AS resultado
FROM (SELECT count(*) AS orfaos FROM lakehouse_rotaperfume.gold.fato_vendas f
      LEFT ANTI JOIN lakehouse_rotaperfume.silver.pedidos p ON p.pedido_id = f.pedido_id);

-- ── 7 · Nenhum cliente órfão ──────────────────────────────────────────
SELECT '7 · nenhum cliente_id órfão no fato' AS teste,
       CAST(orfaos AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN orfaos = 0 THEN 'PASSOU'
            ELSE raise_error(concat(orfaos, ' cliente_id na gold que não existem na silver.clientes'))
       END AS resultado
FROM (SELECT count(*) AS orfaos FROM lakehouse_rotaperfume.gold.fato_vendas f
      LEFT ANTI JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = f.cliente_id);

-- ── 8 · Os marts fecham com o fato ────────────────────────────────────
-- É o teste que prova que "conformado" não é só uma palavra bonita.
SELECT '8 · mart_produto_performance fecha com o fato' AS teste,
       CAST(mart AS STRING) AS calculado, CAST(fato AS STRING) AS esperado,
       CASE WHEN abs(mart - fato) < 0.01 THEN 'PASSOU'
            ELSE raise_error(concat('mart_produto_performance soma ', mart, ' e o fato soma ', fato))
       END AS resultado
FROM (SELECT (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.mart_produto_performance) AS mart,
             (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.fato_vendas)              AS fato);

-- ── 9 · Todo CNPJ com 14 dígitos ──────────────────────────────────────
SELECT '9 · todo CNPJ com 14 dígitos' AS teste,
       CAST(malformados AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN malformados = 0 THEN 'PASSOU'
            ELSE raise_error(concat(malformados, ' CNPJ fora do padrão de 14 dígitos'))
       END AS resultado
FROM (SELECT count(*) AS malformados FROM lakehouse_rotaperfume.silver.clientes
      WHERE length(cnpj) <> 14 OR cnpj RLIKE '[^0-9]');
