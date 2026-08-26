-- Silver · produtos e itens_pedido
--
-- produtos: tipagem simples, data_lancamento com try_to_date (245 produtos
-- sem data de lançamento na origem).
--
-- itens_pedido: quantidade negativa é DEVOLUÇÃO, não erro — a linha fica,
-- marcada. E marcamos também quando o SKU do item já foi descontinuado.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.produtos AS
SELECT
  sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  CAST(preco_tabela AS DECIMAL(18, 2)) AS preco_tabela,
  CAST(custo_unitario AS DECIMAL(18, 2)) AS custo_unitario,
  unidade,
  ativo = 'S' AS ativo,
  try_to_date(data_lancamento, 'yyyy-MM-dd') AS data_lancamento,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.produtos) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.produtos;

COMMENT ON TABLE lakehouse_rotaperfume.silver.produtos IS
  'Catálogo de SKUs limpo: preço e custo tipados, ativo como boolean, data de lançamento convertida.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.produtos.ativo IS
  'Convertido de texto (S/N) para boolean. Produto inativo é usado por silver.itens_pedido para marcar sku_descontinuado.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.produtos.data_lancamento IS
  'Convertida com try_to_date (ANSI mode aborta com to_date em data malformada); 245 produtos vêm sem data na origem e ficam NULL, sem quebrar a query.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.itens_pedido AS
SELECT
  ip.item_id,
  ip.pedido_id,
  ip.sku,
  CAST(ip.quantidade AS INT) AS quantidade,
  CAST(ip.quantidade AS INT) < 0 AS devolucao,
  abs(CAST(ip.quantidade AS INT)) AS quantidade_abs,
  CAST(ip.preco_praticado AS DECIMAL(18, 2)) AS preco_praticado,
  CAST(ip.desconto_pct AS DECIMAL(5, 2)) AS desconto_pct,
  CAST(ip.valor_bruto AS DECIMAL(18, 2)) AS valor_bruto,
  coalesce(p.ativo = 'N', FALSE) AS sku_descontinuado,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.itens_pedido) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.itens_pedido ip
LEFT JOIN lakehouse_rotaperfume.bronze.produtos p
  ON ip.sku = p.sku;

COMMENT ON TABLE lakehouse_rotaperfume.silver.itens_pedido IS
  'Item de pedido tipado, com devolução (2.327 itens) e SKU descontinuado (76 itens) explicitados — nenhuma linha de devolução é descartada.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.itens_pedido.quantidade IS
  'Texto convertido para INT. Pode ser negativo — ver devolucao.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.itens_pedido.devolucao IS
  'quantidade < 0 no ERP é devolução, não erro de digitação. A linha é preservada, nunca descartada.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.itens_pedido.quantidade_abs IS
  'Valor absoluto de quantidade, para contagem de unidades independente de ser venda ou devolução.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.itens_pedido.sku_descontinuado IS
  'TRUE quando o produto referenciado (join com silver.produtos) não está mais ativo — o pedido foi feito com um SKU que hoje saiu de linha.';

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido
  ADD CONSTRAINT itens_pedido_quantidade_abs_positiva CHECK (quantidade_abs > 0);
