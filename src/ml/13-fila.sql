-- ML · a fila semanal
--
-- gold.score_propensao já tem nota para os 3.000 clientes. Esta tarefa
-- transforma nota em AÇÃO: os 200 clientes que o time liga esta semana,
-- um por vendedor, com o motivo escrito em português e um produto para
-- oferecer na ligação.
--
-- ORDEM DAS TRÊS DECISÕES — cada uma resolve um problema diferente:
--
--   1. elegibilidade   só entra quem tem carteira VIGENTE e vendedor ATIVO.
--                       Ligar para o cliente certo com o vendedor errado
--                       (ou desligado) não é fila, é trabalho perdido.
--   2. ORDER BY + LIMIT 200   corta pelo score, na base INTEIRA elegível —
--                       200 é o tamanho real da operação (uma ligação por
--                       vendedor por dia útil), não um limite por vendedor.
--   3. ROW_NUMBER() por vendedor   só DEPOIS do corte, para numerar a ordem
--                       de ligação de quem já ganhou vaga na fila.
--
-- Inverter 2 e 3 daria 200 clientes POR VENDEDOR (milhares de ligações);
-- fazer 3 antes de 1 deixaria vendedor desligado aparecer na fila.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fila_semanal
COMMENT 'A fila semanal de ligação: os 200 clientes de maior score de propensão de compra entre os que têm carteira vigente e vendedor ativo, com a ordem de ligação por vendedor. Fonte da ligação comercial da semana — gold.score_propensao sozinho não filtra carteira nem corta em 200.'
AS
WITH elegiveis AS (
  -- Passo 1: elegibilidade. QUALIFY garante uma linha por cliente mesmo se
  -- o histórico de carteira tiver mais de uma linha vigente por engano.
  SELECT
    v.nome AS vendedor,
    sp.cliente_id,
    dc.razao_social,
    dc.cidade,
    dc.uf,
    sp.score,
    sp.faixa,
    fc.ticket_medio,
    fc.oportunidades_abertas,
    fc.atraso_relativo,
    fc.pedidos_ultimos_90d,
    fc.frequencia_pedidos,
    fc.comprou_lancamento,
    fc.visitas_90d,
    fc.conversao_visita
  FROM lakehouse_rotaperfume.gold.score_propensao sp
  JOIN lakehouse_rotaperfume.gold.features_cliente fc ON fc.cliente_id = sp.cliente_id
  JOIN lakehouse_rotaperfume.gold.dim_cliente dc ON dc.cliente_id = sp.cliente_id
  JOIN lakehouse_rotaperfume.silver.carteira c
    ON c.cliente_id = sp.cliente_id AND c.vigente AND NOT c.orfao_vendedor_desligado
  JOIN lakehouse_rotaperfume.silver.vendedores v ON v.vendedor_id = c.vendedor_id
  QUALIFY ROW_NUMBER() OVER (PARTITION BY sp.cliente_id ORDER BY c.data_inicio DESC) = 1
),

-- Passo 2: os 200 de maior score na base elegível inteira.
top_200 AS (
  SELECT * FROM elegiveis ORDER BY score DESC LIMIT 200
),

-- A sugestão de produto olha só para os 200 que já ganharam a fila — mais
-- barato do que calcular para os 3.000, e é só disso que precisamos aqui.
marca_preferida AS (
  SELECT cliente_id, marca
  FROM (
    SELECT
      f.cliente_id,
      f.marca,
      ROW_NUMBER() OVER (PARTITION BY f.cliente_id ORDER BY SUM(f.receita) DESC) AS rn
    FROM lakehouse_rotaperfume.gold.fato_vendas f
    WHERE f.cliente_id IN (SELECT cliente_id FROM top_200)
    GROUP BY f.cliente_id, f.marca
  )
  WHERE rn = 1
),
sku_candidato AS (
  -- SKU mais comprado dentro da marca preferida, mas que o cliente NÃO
  -- compra há mais de 90 dias — é reposição, não um produto qualquer.
  SELECT
    f.cliente_id,
    f.sku,
    SUM(f.quantidade) AS quantidade_historica,
    ROW_NUMBER() OVER (PARTITION BY f.cliente_id ORDER BY SUM(f.quantidade) DESC) AS rn
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  JOIN marca_preferida mp ON mp.cliente_id = f.cliente_id AND mp.marca = f.marca
  WHERE NOT f.devolucao
  GROUP BY f.cliente_id, f.sku
  HAVING MAX(f.data_pedido) < DATE_SUB(DATE'2026-08-31', 90)
),
sku_top AS (
  SELECT cliente_id, sku FROM sku_candidato WHERE rn = 1
),
estoque_recente AS (
  -- Um saldo por SKU: o snapshot mais recente de silver.estoque.
  SELECT sku, saldo
  FROM (
    SELECT sku, saldo, ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS rn
    FROM lakehouse_rotaperfume.silver.estoque
  )
  WHERE rn = 1
),

fila AS (
  -- Passo 3: a ordem de ligação, só entre quem já está nos 200.
  SELECT
    t.*,
    ROW_NUMBER() OVER (PARTITION BY t.vendedor ORDER BY t.score DESC) AS ordem,
    st.sku      AS sugestao_sku,
    pr.descricao AS sugestao_descricao,
    er.saldo    AS sugestao_saldo
  FROM top_200 t
  LEFT JOIN sku_top st ON st.cliente_id = t.cliente_id
  LEFT JOIN lakehouse_rotaperfume.gold.dim_produto pr ON pr.sku = st.sku
  LEFT JOIN estoque_recente er ON er.sku = st.sku
)
SELECT
  vendedor,
  ordem,
  cliente_id,
  razao_social,
  cidade,
  uf,
  score,
  faixa,
  ticket_medio,
  -- ELSE é obrigatório: score alto sozinho, sem nenhum sinal de CRM ou
  -- ritmo, ainda é um motivo válido para ligar — só não é específico.
  CASE
    WHEN oportunidades_abertas > 0
      THEN 'Tem oportunidade em aberto no funil comercial — ligar para avançar a negociação.'
    WHEN atraso_relativo IS NOT NULL AND atraso_relativo >= 1.5
      THEN 'Está atrasado em relação ao próprio ritmo de compra.'
    WHEN pedidos_ultimos_90d = 0 AND frequencia_pedidos > 0
      THEN 'Não compra há mais de 90 dias.'
    WHEN comprou_lancamento = 1
      THEN 'Comprou lançamento recente — bom momento para oferecer mais.'
    WHEN visitas_90d > 0 AND conversao_visita = 0
      THEN 'Foi visitado recentemente e ainda não converteu em pedido.'
    ELSE 'Score alto de propensão de compra pelo modelo, sem sinal específico de CRM ou ritmo.'
  END AS motivo,
  CASE
    WHEN sugestao_sku IS NOT NULL THEN concat(
      'SKU ', sugestao_sku, ' (', sugestao_descricao, ') — não comprado nos últimos 90 dias. ',
      'Saldo em estoque: ', coalesce(CAST(sugestao_saldo AS STRING), 'sem snapshot'), ' unidades.'
    )
    ELSE 'Sem sugestão de reposição no momento — sem histórico de recompra na marca preferida.'
  END AS sugestao
FROM fila
ORDER BY vendedor, ordem;

ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN vendedor
  COMMENT 'Nome do vendedor responsável pela carteira do cliente (silver.vendedores.nome). Só vendedor ativo com carteira vigente entra na fila.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN ordem
  COMMENT 'Posição do cliente na fila deste vendedor — 1 é o próximo a ligar. Calculada por ROW_NUMBER() sobre os 200 clientes de maior score, particionado por vendedor.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN cliente_id
  COMMENT 'Identificador do cliente. Liga com gold.dim_cliente e gold.score_propensao.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN razao_social
  COMMENT 'Nome do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN cidade
  COMMENT 'Cidade do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN uf
  COMMENT 'UF do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN score
  COMMENT 'Probabilidade de compra nos próximos 7 dias (gold.score_propensao.score). Está entre os 200 maiores scores da base elegível.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN faixa
  COMMENT 'Quartil do score entre todos os 3.000 clientes pontuados: Fria, Morna, Quente, Muito quente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN ticket_medio
  COMMENT 'Ticket médio histórico do cliente (gold.features_cliente.ticket_medio) — quanto ele costuma gastar por pedido.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN motivo
  COMMENT 'Frase em português explicando por que ligar para este cliente agora: oportunidade aberta, atraso no ritmo, ausência de pedido recente, lançamento comprado ou visita sem conversão. Nunca nula — sem sinal específico, cai no motivo genérico de score alto.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN sugestao
  COMMENT 'SKU da marca preferida do cliente (por receita histórica) já comprado por ele mas sem compra nos últimos 90 dias, com o saldo do snapshot mais recente de silver.estoque. Frase genérica quando não há SKU elegível.';


-- ═══════════════ Funções SQL do Unity Catalog ═══════════════
--
-- As quatro ferramentas do agente comercial: uma para priorizar quem ligar,
-- uma para o contexto de um cliente específico, uma para o que oferecer, e
-- uma para conferir estoque antes de prometer o produto por telefone.

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.priorizar_carteira(
  p_vendedor STRING COMMENT 'Nome do vendedor, exatamente como em silver.vendedores.nome / gold.fila_semanal.vendedor.',
  p_quantos INT COMMENT 'Quantos clientes devolver, começando do topo da fila (ordem = 1).'
)
RETURNS TABLE (
  ordem INT COMMENT 'Posição do cliente na fila deste vendedor. 1 é o próximo a ligar.',
  cliente_id INT COMMENT 'Identificador do cliente.',
  razao_social STRING COMMENT 'Nome do cliente.',
  cidade STRING COMMENT 'Cidade do cliente.',
  uf STRING COMMENT 'UF do cliente.',
  score DOUBLE COMMENT 'Probabilidade de compra nos próximos 7 dias.',
  faixa STRING COMMENT 'Quartil do score: Fria, Morna, Quente, Muito quente.',
  motivo STRING COMMENT 'Razão de negócio para ligar para este cliente agora.',
  sugestao STRING COMMENT 'Produto sugerido para oferecer nesta ligação.'
)
COMMENT 'Devolve os p_quantos clientes prioritários da fila semanal de um vendedor, em ordem de ligação. Use para responder "quem eu devo ligar hoje?".'
RETURN
  -- LIMIT não aceita parâmetro de função (INVALID_LIMIT_LIKE_EXPRESSION):
  -- filtra por `ordem`, que já é o rank do vendedor, em vez de LIMIT p_quantos.
  SELECT ordem, cliente_id, razao_social, cidade, uf, score, faixa, motivo, sugestao
  FROM lakehouse_rotaperfume.gold.fila_semanal
  WHERE vendedor = p_vendedor AND ordem <= p_quantos
  ORDER BY ordem;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.contexto_cliente(
  p_cliente_id INT COMMENT 'Identificador do cliente a consultar.'
)
RETURNS TABLE (
  cliente_id INT COMMENT 'Identificador do cliente.',
  razao_social STRING COMMENT 'Nome do cliente.',
  segmento STRING COMMENT 'Tipo de varejo do cliente.',
  cidade STRING COMMENT 'Cidade do cliente.',
  uf STRING COMMENT 'UF do cliente.',
  dias_sem_comprar INT COMMENT 'Dias entre o último pedido do cliente e o último pedido de toda a base.',
  total_pedidos INT COMMENT 'Total histórico de pedidos do cliente.',
  receita_acumulada DECIMAL(18, 2) COMMENT 'Receita acumulada do cliente em toda a base.',
  score DOUBLE COMMENT 'Probabilidade de compra nos próximos 7 dias, do modelo de propensão. NULL se o cliente ainda não foi pontuado.',
  faixa STRING COMMENT 'Quartil do score: Fria, Morna, Quente, Muito quente. NULL se o cliente ainda não foi pontuado.',
  oportunidades_abertas INT COMMENT 'Oportunidades do cliente ainda em aberto no CRM.',
  visitas_90d INT COMMENT 'Visitas do vendedor ao cliente nos 90 dias antes do corte do modelo (31/08/2026).',
  na_fila_semanal BOOLEAN COMMENT 'TRUE se o cliente está entre os 200 priorizados da fila semanal atual.',
  motivo STRING COMMENT 'Motivo de priorização em gold.fila_semanal. NULL quando na_fila_semanal é FALSE.'
)
COMMENT 'Devolve o retrato comercial completo de um cliente: cadastro, RFM resumido, score de propensão e se está na fila semanal. Use para responder "me conta sobre o cliente X" antes de uma ligação.'
RETURN
  SELECT
    dc.cliente_id,
    dc.razao_social,
    dc.segmento,
    dc.cidade,
    dc.uf,
    dc.dias_sem_comprar,
    CAST(dc.total_pedidos AS INT),
    dc.receita_acumulada,
    sp.score,
    sp.faixa,
    fc.oportunidades_abertas,
    fc.visitas_90d,
    fs.cliente_id IS NOT NULL AS na_fila_semanal,
    fs.motivo
  FROM lakehouse_rotaperfume.gold.dim_cliente dc
  LEFT JOIN lakehouse_rotaperfume.gold.score_propensao sp ON sp.cliente_id = dc.cliente_id
  LEFT JOIN lakehouse_rotaperfume.gold.features_cliente fc ON fc.cliente_id = dc.cliente_id
  LEFT JOIN lakehouse_rotaperfume.gold.fila_semanal fs ON fs.cliente_id = dc.cliente_id
  WHERE dc.cliente_id = p_cliente_id;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.sugerir_produtos(
  p_cliente_id INT COMMENT 'Identificador do cliente para quem sugerir produtos.'
)
RETURNS TABLE (
  sku STRING COMMENT 'Código do produto sugerido.',
  descricao STRING COMMENT 'Descrição do produto.',
  marca STRING COMMENT 'Marca do produto — a preferida deste cliente, por receita histórica.',
  quantidade_historica BIGINT COMMENT 'Soma da quantidade já comprada deste SKU pelo cliente, excluindo devolução.',
  ultima_compra DATE COMMENT 'Data do último pedido deste SKU pelo cliente.',
  saldo_estoque INT COMMENT 'Saldo do snapshot mais recente de silver.estoque para este SKU. NULL se o SKU nunca teve snapshot.'
)
COMMENT 'Sugere até 5 SKUs da marca preferida do cliente que ele já comprou mas não compra há mais de 90 dias, com o saldo de estoque atual. Use para responder "o que eu ofereço para esse cliente?".'
RETURN
  WITH marca_preferida AS (
    SELECT cliente_id, marca
    FROM (
      SELECT
        cliente_id,
        marca,
        ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY SUM(receita) DESC) AS rn
      FROM lakehouse_rotaperfume.gold.fato_vendas
      WHERE cliente_id = p_cliente_id
      GROUP BY cliente_id, marca
    )
    WHERE rn = 1
  ),
  candidatos AS (
    SELECT
      f.sku,
      SUM(f.quantidade) AS quantidade_historica,
      MAX(f.data_pedido) AS ultima_compra
    FROM lakehouse_rotaperfume.gold.fato_vendas f
    JOIN marca_preferida mp ON mp.marca = f.marca
    WHERE f.cliente_id = p_cliente_id AND NOT f.devolucao
    GROUP BY f.sku
    HAVING MAX(f.data_pedido) < DATE_SUB(DATE'2026-08-31', 90)
  )
  SELECT
    c.sku,
    pr.descricao,
    pr.marca,
    c.quantidade_historica,
    c.ultima_compra,
    er.saldo AS saldo_estoque
  FROM candidatos c
  JOIN lakehouse_rotaperfume.gold.dim_produto pr ON pr.sku = c.sku
  LEFT JOIN (
    SELECT sku, saldo
    FROM (
      SELECT sku, saldo, ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS rn
      FROM lakehouse_rotaperfume.silver.estoque
    )
    WHERE rn = 1
  ) er ON er.sku = c.sku
  ORDER BY c.quantidade_historica DESC
  LIMIT 5;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.checar_disponibilidade(
  p_sku STRING COMMENT 'Código do SKU a consultar (gold.dim_produto.sku).'
)
RETURNS TABLE (
  sku STRING COMMENT 'Código do produto.',
  descricao STRING COMMENT 'Descrição do produto.',
  marca STRING COMMENT 'Marca do produto.',
  descontinuado BOOLEAN COMMENT 'TRUE quando o produto não está mais ativo no cadastro.',
  data_snapshot DATE COMMENT 'Data do snapshot de estoque mais recente usado nesta consulta. NULL se o SKU nunca teve snapshot.',
  saldo INT COMMENT 'Saldo em unidades no snapshot mais recente. NULL se o SKU nunca teve snapshot.',
  ruptura BOOLEAN COMMENT 'TRUE quando o saldo do snapshot mais recente é zero. NULL se o SKU nunca teve snapshot.'
)
COMMENT 'Devolve o saldo de estoque mais recente de um SKU, com o cadastro do produto. Use para confirmar disponibilidade antes de sugerir o produto numa ligação.'
RETURN
  SELECT
    pr.sku,
    pr.descricao,
    pr.marca,
    pr.descontinuado,
    e.data_snapshot,
    e.saldo,
    e.ruptura
  FROM lakehouse_rotaperfume.gold.dim_produto pr
  LEFT JOIN (
    SELECT sku, data_snapshot, saldo, ruptura
    FROM (
      SELECT sku, data_snapshot, saldo, ruptura,
             ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS rn
      FROM lakehouse_rotaperfume.silver.estoque
    )
    WHERE rn = 1
  ) e ON e.sku = pr.sku
  WHERE pr.sku = p_sku;


-- ═══════════════ Três testes ═══════════════
--
-- Mesmo padrão da gold (08-testes.sql): raise_error() dentro de CASE WHEN
-- interrompe a tarefa. Uma fila errada tira o time de vendas do ar tanto
-- quanto um número de receita errado no dashboard.

-- ── 1 · A fila tem exatamente 200 linhas ──────────────────────────────
SELECT '1 · fila_semanal tem exatamente 200 linhas' AS teste,
       CAST(linhas AS STRING) AS calculado, '200' AS esperado,
       CASE WHEN linhas = 200 THEN 'PASSOU'
            ELSE raise_error(concat('fila_semanal tem ', linhas, ' linhas, esperado exatamente 200'))
       END AS resultado
FROM (SELECT count(*) AS linhas FROM lakehouse_rotaperfume.gold.fila_semanal);

-- ── 2 · Nenhum motivo nulo ou vazio ───────────────────────────────────
SELECT '2 · nenhum motivo nulo ou vazio' AS teste,
       CAST(invalidos AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN invalidos = 0 THEN 'PASSOU'
            ELSE raise_error(concat(invalidos, ' linhas de fila_semanal com motivo nulo ou vazio'))
       END AS resultado
FROM (SELECT count(*) AS invalidos FROM lakehouse_rotaperfume.gold.fila_semanal
      WHERE motivo IS NULL OR trim(motivo) = '');

-- ── 3 · Nenhum score fora de [0, 1] ───────────────────────────────────
SELECT '3 · nenhum score fora de [0, 1]' AS teste,
       CAST(fora AS STRING) AS calculado, '0' AS esperado,
       CASE WHEN fora = 0 THEN 'PASSOU'
            ELSE raise_error(concat(fora, ' linhas de fila_semanal com score fora do intervalo [0, 1]'))
       END AS resultado
FROM (SELECT count(*) AS fora FROM lakehouse_rotaperfume.gold.fila_semanal
      WHERE score < 0 OR score > 1);
