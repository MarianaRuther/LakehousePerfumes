-- Gold · data marts, um por diretoria
--
-- O ERRO CLÁSSICO é criar um fato por área: fato_vendas_comercial e
-- fato_vendas_produto. Em três meses eles divergem, ninguém sabe qual está
-- certo, e a empresa passa a ter duas verdades.
--
-- O que separa um mart do outro NÃO é a tabela base — é a DIMENSÃO DOMINANTE
-- e as MÉTRICAS. Os dois primeiros aqui leem o mesmo gold.fato_vendas, e os
-- dois somam a mesma receita. É isso que "conformado" significa.
--
--   Diretoria     Pergunta que só ela faz              Coluna que só ela usa
--   ───────────────────────────────────────────────────────────────────────
--   Vendas        qual vendedor está abaixo da meta?   meta_mensal
--   Produto       vendo o dobro e ganho menos?         custo_unitario
--   Financeiro    quanto entra em caixa em 30 dias?    data_vencimento

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor
COMMENT 'Mart da diretoria de Vendas. Grão: vendedor × mês. Responde meta, produtividade e cobertura de carteira.'
AS
SELECT
  f.vendedor_id,
  v.nome                                                             AS vendedor,
  v.regiao,
  f.ano,
  f.mes,
  v.meta_mensal,
  ROUND(SUM(f.receita), 2)                                           AS receita,
  ROUND(SUM(f.margem), 2)                                            AS margem,
  ROUND(SUM(f.receita) / nullif(v.meta_mensal, 0), 4)                AS atingimento_meta,
  COUNT(DISTINCT f.cliente_id)                                       AS clientes_atendidos,
  ROUND(SUM(f.receita) / nullif(COUNT(DISTINCT f.pedido_id), 0), 2)  AS ticket_medio
FROM lakehouse_rotaperfume.gold.fato_vendas f
JOIN lakehouse_rotaperfume.gold.dim_vendedor v ON v.vendedor_id = f.vendedor_id
GROUP BY f.vendedor_id, v.nome, v.regiao, f.ano, f.mes, v.meta_mensal;

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_produto_performance
COMMENT 'Mart da diretoria de Produto. Grão: SKU × mês, com curva ABC calculada sobre a receita do período inteiro.'
AS
WITH por_sku AS (
  SELECT sku, SUM(receita) AS receita_total
  FROM lakehouse_rotaperfume.gold.fato_vendas
  GROUP BY sku
),
-- Curva ABC: ordena por receita e acumula. A é quem faz os primeiros 80% do
-- faturamento, B vai até 95%, C é a cauda — a conta mais simples que já muda
-- decisão de mix de produto.
abc AS (
  SELECT
    sku,
    SUM(receita_total) OVER (ORDER BY receita_total DESC
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
      / SUM(receita_total) OVER () AS acumulado_pct
  FROM por_sku
)
SELECT
  f.sku,
  p.descricao,
  p.marca,
  p.categoria,
  p.nota_olfativa,
  f.ano,
  f.mes,
  SUM(abs(f.quantidade))                                 AS quantidade,
  ROUND(SUM(f.receita), 2)                               AS receita,
  ROUND(SUM(f.margem), 2)                                AS margem,
  ROUND(SUM(f.margem) / nullif(SUM(f.receita), 0), 4)    AS margem_pct,
  MAX(a.curva_abc)                                       AS curva_abc
FROM lakehouse_rotaperfume.gold.fato_vendas f
JOIN lakehouse_rotaperfume.gold.dim_produto p ON p.sku = f.sku
JOIN (
  SELECT sku,
         CASE WHEN acumulado_pct <= 0.80 THEN 'A'
              WHEN acumulado_pct <= 0.95 THEN 'B'
              ELSE 'C' END AS curva_abc
  FROM abc
) a ON a.sku = f.sku
GROUP BY f.sku, p.descricao, p.marca, p.categoria, p.nota_olfativa, f.ano, f.mes;

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento
COMMENT 'Mart da diretoria Financeira. Grão: mês de vencimento. Responde quanto entra em caixa, com que atraso e a que custo de taxa.'
AS
WITH pagamento_calculado AS (
  SELECT
    year(pg.data_vencimento)  AS ano_vencimento,
    month(pg.data_vencimento) AS mes_vencimento,
    pg.valor,
    pg.valor_liquido,
    -- silver.pagamentos não traz `recebido` nem `dias_de_atraso` prontos —
    -- só o texto de status_pagamento ('Pago', 'Pago com atraso', 'Em aberto',
    -- 'Inadimplente') e as duas datas. Derivamos os dois aqui.
    pg.status_pagamento IN ('Pago', 'Pago com atraso') AS recebido,
    CASE
      WHEN pg.data_pagamento IS NOT NULL
      THEN datediff(pg.data_pagamento, pg.data_vencimento)
    END AS dias_de_atraso
  FROM lakehouse_rotaperfume.silver.pagamentos pg
  JOIN lakehouse_rotaperfume.silver.pedidos p
    ON p.pedido_id = pg.pedido_id AND NOT p.cancelado
  WHERE pg.data_vencimento IS NOT NULL
)
SELECT
  ano_vencimento,
  mes_vencimento,
  COUNT(*)                                                                  AS titulos,
  ROUND(SUM(valor), 2)                                                      AS valor_a_receber,
  ROUND(SUM(CASE WHEN recebido THEN valor ELSE 0 END), 2)                   AS valor_recebido,
  ROUND(AVG(CASE WHEN recebido AND dias_de_atraso > 0 THEN dias_de_atraso END), 1) AS atraso_medio_dias,
  ROUND(SUM(valor - valor_liquido), 2)                                      AS custo_de_taxa
FROM pagamento_calculado
GROUP BY ano_vencimento, mes_vencimento;

ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN atingimento_meta
  COMMENT 'Receita do vendedor no mês dividida pela meta mensal. 1,0 é exatamente a meta batida.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN ticket_medio
  COMMENT 'Receita do mês dividida pelo número de pedidos distintos (não de itens).';

ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN curva_abc
  COMMENT 'A: SKUs que somam os primeiros 80% da receita do período inteiro. B: até 95%. C: a cauda. Calculada uma vez sobre todo o período, não por mês.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN valor_recebido
  COMMENT 'Soma de valor só dos títulos com status_pagamento ''Pago'' ou ''Pago com atraso''. Título em aberto ou inadimplente entra em valor_a_receber mas não aqui.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN atraso_medio_dias
  COMMENT 'Média de dias entre vencimento e pagamento, só para títulos recebidos em atraso (dias_de_atraso > 0). Título pago em dia ou ainda em aberto não entra nesta média.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN custo_de_taxa
  COMMENT 'Diferença entre o valor do título e o valor líquido creditado — o que a forma de pagamento (maquininha, boleto, etc.) cobra de taxa.';
