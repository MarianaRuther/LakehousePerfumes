-- Gold · views com nome de negócio
--
-- Ninguém da diretoria pergunta por `fato_vendas`. Perguntam por *ranking de
-- marcas* ou por *clientes em risco*. A view existe para que o nome da
-- pergunta e o nome da tabela sejam a mesma palavra — é assim que o Genie
-- acerta de primeira em vez de tentar adivinhar qual JOIN fazer.
--
-- O COMMENT de cada view diz QUAL PERGUNTA DE NEGÓCIO ela responde, não o
-- que ela é: é isso que o Genie lê para decidir onde procurar.

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.receita_mensal (
  ano            COMMENT 'Ano do pedido.',
  mes            COMMENT 'Mês do pedido, de 1 a 12.',
  mes_pico_setor COMMENT 'TRUE em abril, junho e outubro — os picos da distribuidora, porque o varejo compra ANTES da data comemorativa. Vem de gold.dim_calendario, a mesma regra usada no resto da gold.',
  receita        COMMENT 'Soma de receita do mês. Já inclui devolução, que entra negativa.',
  margem         COMMENT 'Soma de margem do mês: receita menos custo do produto.',
  margem_pct     COMMENT 'Margem dividida pela receita do mês, de 0 a 1.',
  pedidos        COMMENT 'Pedidos distintos faturados no mês (COUNT DISTINCT pedido_id, nunca COUNT(*), que contaria item).',
  ticket_medio   COMMENT 'Receita do mês dividida pelo número de pedidos distintos.'
)
COMMENT 'Responde: qual foi a receita e a margem em cada mês, e o mês foi um pico esperado do setor ou uma queda de verdade? Base para explicar variação mensal sem confundir sazonalidade normal com problema.'
AS
SELECT
  f.ano,
  f.mes,
  c.mes_pico_setor,
  ROUND(SUM(f.receita), 2)                                          AS receita,
  ROUND(SUM(f.margem), 2)                                           AS margem,
  ROUND(SUM(f.margem) / nullif(SUM(f.receita), 0), 4)               AS margem_pct,
  COUNT(DISTINCT f.pedido_id)                                       AS pedidos,
  ROUND(SUM(f.receita) / nullif(COUNT(DISTINCT f.pedido_id), 0), 2) AS ticket_medio
FROM lakehouse_rotaperfume.gold.fato_vendas f
-- mes_pico_setor só depende do mês, não do ano — por isso o DISTINCT antes
-- do join, em vez de cruzar com os 24 meses inteiros de dim_calendario.
LEFT JOIN (SELECT DISTINCT mes, mes_pico_setor FROM lakehouse_rotaperfume.gold.dim_calendario) c
  ON c.mes = f.mes
GROUP BY f.ano, f.mes, c.mes_pico_setor;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.ranking_marcas (
  marca             COMMENT 'Marca do produto.',
  receita           COMMENT 'Receita total da marca no período inteiro da base.',
  margem            COMMENT 'Margem total da marca no período inteiro.',
  margem_pct        COMMENT 'Margem dividida pela receita da marca, de 0 a 1.',
  participacao_pct  COMMENT 'Receita da marca dividida pela receita de todas as marcas — a fatia da marca no faturamento total, de 0 a 1.',
  skus              COMMENT 'Quantidade de SKUs distintos vendidos da marca.',
  pedidos           COMMENT 'Pedidos distintos que continham algum item da marca.'
)
COMMENT 'Responde: quais marcas mais faturam, quais dão mais margem, e qual o peso de cada uma no total vendido? Para decidir onde concentrar negociação com fornecedor e esforço comercial.'
AS
SELECT
  marca,
  ROUND(SUM(receita), 2)                                AS receita,
  ROUND(SUM(margem), 2)                                 AS margem,
  ROUND(SUM(margem) / nullif(SUM(receita), 0), 4)       AS margem_pct,
  ROUND(SUM(receita) / SUM(SUM(receita)) OVER (), 4)    AS participacao_pct,
  COUNT(DISTINCT sku)                                   AS skus,
  COUNT(DISTINCT pedido_id)                             AS pedidos
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY marca;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.margem_por_categoria (
  categoria  COMMENT 'Categoria do produto: Eau de Parfum, Óleo Concentrado, Bakhoor, Kit Presente, entre outras.',
  receita    COMMENT 'Receita total da categoria no período inteiro.',
  margem     COMMENT 'Margem total da categoria no período inteiro.',
  margem_pct COMMENT 'Margem dividida pela receita da categoria, de 0 a 1. A margem varia muito entre categorias.',
  pecas      COMMENT 'Peças movimentadas na categoria, em valor absoluto (venda e devolução contam igual, sem sinal).'
)
COMMENT 'Responde: em qual categoria de produto a empresa ganha margem, e em qual só faz volume? Para decidir onde empurrar o mix de venda.'
AS
SELECT
  categoria,
  ROUND(SUM(receita), 2)                          AS receita,
  ROUND(SUM(margem), 2)                           AS margem,
  ROUND(SUM(margem) / nullif(SUM(receita), 0), 4) AS margem_pct,
  SUM(abs(quantidade))                            AS pecas
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY categoria;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.clientes_em_risco (
  cliente_id           COMMENT 'Identificador do cliente.',
  razao_social         COMMENT 'Nome do cliente.',
  segmento             COMMENT 'Tipo de varejo do cliente.',
  cidade               COMMENT 'Cidade do cliente.',
  ultimo_pedido        COMMENT 'Data do último pedido do cliente.',
  dias_sem_comprar     COMMENT 'Dias entre o último pedido do cliente e o último pedido de toda a base (não a data de hoje — o dataset é fixo). Em risco = mais de 90 dias.',
  total_pedidos        COMMENT 'Quantos pedidos o cliente já fez, no total.',
  receita_mensal_media COMMENT 'Receita acumulada do cliente dividida pelos meses entre o primeiro e o último pedido — quanto ele costumava comprar por mês antes de sumir. É a receita que se perde por mês se ele não voltar.'
)
COMMENT 'Responde: quais clientes pararam de comprar (mais de 90 dias sem pedido, ou seja, churn), e quanta receita mensal a empresa está deixando de fazer por causa disso? Para priorizar quem o time comercial reativa primeiro.'
AS
SELECT
  c.cliente_id,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.ultimo_pedido,
  c.dias_sem_comprar,
  c.total_pedidos,
  ROUND(c.receita_acumulada / nullif(months_between(c.ultimo_pedido, c.primeiro_pedido), 0), 2) AS receita_mensal_media
FROM lakehouse_rotaperfume.gold.dim_cliente c
WHERE c.dias_sem_comprar > 90;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.efeito_lancamento (
  sku                 COMMENT 'Código do produto.',
  descricao           COMMENT 'Descrição do produto.',
  marca               COMMENT 'Marca do produto.',
  data_lancamento     COMMENT 'Data de lançamento do SKU no cadastro. SKUs sem data de lançamento na origem (245 produtos) não aparecem nesta view.',
  receita_120_dias    COMMENT 'Receita do SKU nos 120 dias corridos após o lançamento.',
  receita_depois      COMMENT 'Receita do SKU do 121º dia após o lançamento em diante.',
  receita_total       COMMENT 'Receita total do SKU no período inteiro da base.',
  peso_do_lancamento  COMMENT 'Fatia da receita total do SKU que veio dos 120 primeiros dias, de 0 a 1. Quanto maior, mais forte é o efeito de novidade e mais o produto esfria depois.'
)
COMMENT 'Responde: um SKU recém-lançado vende mais forte logo no início por efeito de novidade, ou o ritmo de venda se mantém depois? Quanto da receita de cada lançamento vem só da janela inicial de 120 dias.'
AS
SELECT
  p.sku,
  p.descricao,
  p.marca,
  p.data_lancamento,
  ROUND(SUM(CASE WHEN datediff(f.data_pedido, p.data_lancamento) BETWEEN 0 AND 120
                 THEN f.receita ELSE 0 END), 2) AS receita_120_dias,
  ROUND(SUM(CASE WHEN datediff(f.data_pedido, p.data_lancamento) > 120
                 THEN f.receita ELSE 0 END), 2) AS receita_depois,
  ROUND(SUM(f.receita), 2) AS receita_total,
  ROUND(SUM(CASE WHEN datediff(f.data_pedido, p.data_lancamento) BETWEEN 0 AND 120
                 THEN f.receita ELSE 0 END) / nullif(SUM(f.receita), 0), 4) AS peso_do_lancamento
FROM lakehouse_rotaperfume.gold.fato_vendas f
JOIN lakehouse_rotaperfume.gold.dim_produto p ON p.sku = f.sku
WHERE p.data_lancamento IS NOT NULL
GROUP BY p.sku, p.descricao, p.marca, p.data_lancamento;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.ruptura_por_marca (
  marca                COMMENT 'Marca do produto.',
  snapshots            COMMENT 'Quantidade de leituras semanais de estoque consideradas para SKUs da marca.',
  snapshots_em_ruptura COMMENT 'Quantas dessas leituras tinham saldo zerado.',
  ruptura_pct          COMMENT 'snapshots_em_ruptura dividido por snapshots, de 0 a 1 — a fração do tempo em que a marca teve algum SKU zerado no estoque.',
  saldo_medio          COMMENT 'Saldo médio em unidades, nas leituras de estoque da marca.'
)
COMMENT 'Responde: qual marca mais sofre com falta de produto em estoque (ruptura)? Em perfumaria a venda não migra para outro produto quando falta o da moda — ela simplesmente some. Para priorizar reposição e cobrar fornecedor por marca.'
AS
SELECT
  p.marca,
  COUNT(*)                                                  AS snapshots,
  SUM(CASE WHEN e.ruptura THEN 1 ELSE 0 END)                AS snapshots_em_ruptura,
  ROUND(AVG(CASE WHEN e.ruptura THEN 1.0 ELSE 0.0 END), 4)  AS ruptura_pct,
  ROUND(AVG(e.saldo), 1)                                    AS saldo_medio
FROM lakehouse_rotaperfume.silver.estoque e
JOIN lakehouse_rotaperfume.gold.dim_produto p ON p.sku = e.sku
GROUP BY p.marca;
