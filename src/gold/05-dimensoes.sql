-- Gold · dimensões conformadas
--
-- "Conformada" quer dizer: existe UMA dim_cliente para a empresa inteira. Se
-- vendas e financeiro tiverem cada um a sua, em três meses elas divergem e a
-- reunião vira uma discussão sobre qual sistema está certo — em vez de sobre
-- o que fazer com o número.
--
-- Dimensão responde "quem/o quê/quando". Fato responde "quanto". Se está em
-- dúvida sobre onde uma coluna mora: se soma, é fato.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_cliente
COMMENT 'Uma linha por cliente, com o resumo do relacionamento comercial. Dimensão conformada: é esta que todo mart usa.'
AS
WITH pedidos_do_cliente AS (
  SELECT
    cliente_id,
    min(data_pedido)   AS primeiro_pedido,
    max(data_pedido)   AS ultimo_pedido,
    count(*)           AS total_pedidos,
    sum(valor_liquido) AS receita_acumulada
  FROM lakehouse_rotaperfume.silver.pedidos
  WHERE NOT cancelado
  GROUP BY cliente_id
)
SELECT
  c.cliente_id,
  c.cnpj,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.uf,
  c.data_cadastro,
  p.primeiro_pedido,
  p.ultimo_pedido,
  coalesce(p.total_pedidos, 0)     AS total_pedidos,
  coalesce(p.receita_acumulada, 0) AS receita_acumulada,
  -- Referência é o último pedido de TODA a base, não a data de hoje: o
  -- dataset é fixo (seed 42) e todo aluno precisa chegar no mesmo número,
  -- não num número que muda conforme o dia em que o pipeline roda.
  datediff(
    (SELECT max(data_pedido) FROM lakehouse_rotaperfume.silver.pedidos),
    p.ultimo_pedido
  ) AS dias_sem_comprar
FROM lakehouse_rotaperfume.silver.clientes c
LEFT JOIN pedidos_do_cliente p ON p.cliente_id = c.cliente_id;

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_produto
COMMENT 'Uma linha por SKU: marca, categoria, nota olfativa, custo e status de linha.'
AS
SELECT
  sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  custo_unitario,
  preco_tabela,
  data_lancamento,
  -- silver.produtos só guarda `ativo` (S/N convertido para boolean).
  -- "Descontinuado" é a mesma informação, olhada do outro lado.
  NOT ativo AS descontinuado
FROM lakehouse_rotaperfume.silver.produtos;

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_vendedor
COMMENT 'Uma linha por vendedor: região, meta mensal e situação.'
AS
SELECT
  vendedor_id,
  nome,
  regiao,
  meta_mensal,
  -- silver.vendedores não traz uma flag `ativo` — só data_desligamento.
  -- Vendedor sem data de desligamento está ativo.
  data_desligamento IS NULL AS ativo
FROM lakehouse_rotaperfume.silver.vendedores;

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_calendario
COMMENT 'Um dia por linha nos 24 meses da operação (set/2024 a ago/2026). mes_pico_setor carrega a regra de sazonalidade da distribuição.'
AS
SELECT
  d                      AS data,
  year(d)                AS ano,
  month(d)                AS mes,
  date_format(d, 'MMMM') AS nome_mes,
  quarter(d)              AS trimestre,
  date_format(d, 'EEEE') AS dia_semana,
  -- A REGRA QUE NENHUM MODELO ADIVINHA: o pico da distribuidora é o mês
  -- ANTERIOR à data comemorativa, porque o varejo compra antes.
  --   abril   → reposição para o Dia das Mães
  --   junho   → Dia dos Namorados
  --   outubro → reposição para a Black Friday
  -- Dezembro e janeiro são vale: o varejo já está abastecido.
  (month(d) IN (4, 6, 10)) AS mes_pico_setor
FROM (SELECT explode(sequence(DATE'2024-09-01', DATE'2026-08-31', INTERVAL 1 DAY)) AS d);

ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN dias_sem_comprar
  COMMENT 'Dias entre o último pedido do cliente e o último pedido registrado em TODA a base (não a data de hoje — o dataset é fixo). Acima de 90 dias, cliente em risco.';
ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN receita_acumulada
  COMMENT 'Soma de valor_liquido dos pedidos não cancelados do cliente. Pode incluir efeito de devolução, que reduz valor_liquido do pedido em que ocorreu.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_produto ALTER COLUMN descontinuado
  COMMENT 'TRUE quando o produto não está mais ativo no cadastro (derivado de silver.produtos.ativo). Produto descontinuado pode ainda aparecer em fato_vendas, em pedidos antigos.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_vendedor ALTER COLUMN ativo
  COMMENT 'TRUE quando o vendedor não tem data_desligamento preenchida. Ver silver.carteira.orfao_vendedor_desligado para carteiras que ficaram vigentes com vendedor já desligado.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_calendario ALTER COLUMN mes_pico_setor
  COMMENT 'TRUE em abril, junho e outubro. O pico da distribuidora é o mês ANTERIOR à data comemorativa, porque o varejo compra antes — dezembro e janeiro são vale, não queda de desempenho.';
