-- Gold · fato_vendas
--
-- ════════════════════ O CONTRATO, ESCRITO ANTES DO SQL ════════════════════
--
--   GRANULARIDADE  uma linha por ITEM de pedido
--   FILTRO         exclui pedido cancelado. NÃO exclui devolução.
--   DIMENSÕES      data_pedido, ano, mes, canal, cliente_id, razao_social,
--                  segmento, cidade, vendedor_id, sku, categoria, marca,
--                  nota_olfativa
--   MÉTRICAS       quantidade, preco_praticado, receita, custo, margem,
--                  devolucao
--   PARTIÇÃO       ano, mes
--
-- Escrever isso numa frase antes de abrir o editor evita seis meses de
-- discussão sobre o que a tabela significa.
--
-- ─────────────── POR QUE A DEVOLUÇÃO FICA DENTRO DO FATO ───────────────
--
-- Tirar devolução parece certo: "receita é o que vendeu". Mas aí a gold soma
-- R$ 103,6 mi e a silver soma R$ 102,3 mi — R$ 1,26 milhão de diferença entre
-- duas camadas do MESMO pipeline. Um dia alguém compara os dois relatórios
-- numa reunião, e a discussão vira sobre qual sistema está certo.
--
-- Ela fica dentro, com quantidade e receita NEGATIVAS, marcada pela flag.
-- Quem quer o bruto vendido pede:
--     SUM(receita) FILTER (WHERE NOT devolucao)
-- Os dois números existem, e os dois reconciliam.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fato_vendas
COMMENT 'Fato de vendas no grão de item de pedido. Exclui pedido cancelado; inclui devolução com quantidade e receita negativas, marcada pela flag. Soma exatamente a receita da silver.'
PARTITIONED BY (ano, mes)
AS
SELECT
  -- chaves
  i.item_id,
  i.pedido_id,
  p.cliente_id,
  p.vendedor_id,
  i.sku,

  -- dimensões de tempo
  p.data_pedido,
  p.ano,
  p.mes,

  -- dimensões de negócio, desnormalizadas de propósito: quem consome a gold
  -- não deveria precisar de JOIN para responder "receita por marca".
  p.canal,
  c.razao_social,
  c.segmento,
  c.cidade,
  pr.categoria,
  pr.marca,
  pr.nota_olfativa,

  -- métricas
  i.quantidade,
  i.preco_praticado,
  i.valor_bruto                                                AS receita,
  CAST(i.quantidade * pr.custo_unitario AS DECIMAL(18, 2))      AS custo,
  CAST(i.valor_bruto - (i.quantidade * pr.custo_unitario) AS DECIMAL(18, 2)) AS margem,
  i.devolucao
FROM lakehouse_rotaperfume.silver.itens_pedido i
JOIN lakehouse_rotaperfume.silver.pedidos  p  ON p.pedido_id  = i.pedido_id
JOIN lakehouse_rotaperfume.silver.produtos pr ON pr.sku       = i.sku
JOIN lakehouse_rotaperfume.gold.dim_cliente c ON c.cliente_id = p.cliente_id
WHERE NOT p.cancelado;

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN item_id
  COMMENT 'Identificador do item dentro do pedido. Chave primária do fato.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN pedido_id
  COMMENT 'Identificador do pedido no ERP. Use COUNT(DISTINCT pedido_id) para contar pedidos, nunca COUNT(*).';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN cliente_id
  COMMENT 'Identificador do cliente. Liga com gold.dim_cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN vendedor_id
  COMMENT 'Vendedor responsável pelo pedido. Liga com gold.dim_vendedor.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN sku
  COMMENT 'Código do produto vendido. Liga com gold.dim_produto.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN data_pedido
  COMMENT 'Data em que o pedido foi feito. Período da base: setembro/2024 a agosto/2026.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN ano
  COMMENT 'Ano do pedido. Coluna de partição.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN mes
  COMMENT 'Mês do pedido, de 1 a 12. Coluna de partição. Abril, junho e outubro são os picos do setor — ver gold.dim_calendario.mes_pico_setor.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN canal
  COMMENT 'Canal de entrada do pedido: Visita, WhatsApp, E-commerce ou Televendas.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN razao_social
  COMMENT 'Nome do cliente que comprou, já padronizado na silver.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN segmento
  COMMENT 'Tipo de varejo do cliente: Perfumaria, Farmácia, Loja de shopping, Revendedora autônoma, E-commerce, Salão de beleza, Loja de departamento ou Quiosque.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN cidade
  COMMENT 'Cidade do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN categoria
  COMMENT 'Categoria do produto: Eau de Parfum, Óleo Concentrado, Bakhoor, Kit Presente, entre outras. A margem varia muito entre elas.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN marca
  COMMENT 'Marca do produto.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN nota_olfativa
  COMMENT 'Família olfativa do perfume: amadeirado, oriental, floral, cítrico e outras.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN quantidade
  COMMENT 'Quantidade vendida, NEGATIVA quando é devolução (ver devolucao). Para contar peças movimentadas use ABS(quantidade).';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN preco_praticado
  COMMENT 'Preço unitário efetivamente cobrado, já com o desconto comercial aplicado.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN receita
  COMMENT 'Valor do item vendido. NEGATIVA quando é devolução. Para o bruto vendido (sem devolução) use SUM(receita) FILTER (WHERE NOT devolucao).';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN custo
  COMMENT 'Quantidade multiplicada pelo custo unitário do produto no cadastro. Não considera frete nem custo de aquisição variável. Negativo em devolução, simetricamente à receita.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN margem
  COMMENT 'Receita menos custo do produto. NÃO considera desconto comercial já embutido no preço praticado, nem frete, nem taxa de pagamento.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN devolucao
  COMMENT 'TRUE quando a linha é uma devolução (quantidade e receita negativas). Fica dentro do fato de propósito, para a gold reconciliar exatamente com a silver — ver o comentário no topo deste arquivo.';
