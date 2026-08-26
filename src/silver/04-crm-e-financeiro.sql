-- Silver · vendedores, carteira, oportunidades, visitas, pagamentos, estoque
--
-- O ponto mais delicado aqui é carteira: existe vendedor desligado com
-- carteira ainda vigente no cadastro. Não é para consertar — é para EXPOR
-- (orfao_vendedor_desligado) e deixar o gestor decidir.
--
-- etapa em oportunidades: confirmado via SELECT DISTINCT antes de escrever
-- o CASE — os valores de origem são 'Fechado ganho' e 'Fechado perdido',
-- não 'Ganha'/'Perdida'.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.vendedores AS
SELECT
  vendedor_id,
  nome,
  regiao,
  uf,
  try_to_date(data_admissao, 'yyyy-MM-dd') AS data_admissao,
  try_to_date(data_desligamento, 'yyyy-MM-dd') AS data_desligamento,
  CAST(meta_mensal AS DECIMAL(18, 2)) AS meta_mensal,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.vendedores) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.vendedores;

COMMENT ON TABLE lakehouse_rotaperfume.silver.vendedores IS
  'Equipe comercial tipada: datas de admissão e desligamento convertidas com try_to_date, meta em DECIMAL.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.vendedores.data_desligamento IS
  'NULL para vendedor ainda ativo. Usada por silver.carteira para expor carteira órfã de vendedor desligado.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.carteira AS
WITH convertido AS (
  SELECT
    c.carteira_id,
    c.cliente_id,
    c.vendedor_id,
    try_to_date(c.data_inicio, 'yyyy-MM-dd') AS data_inicio,
    try_to_date(c.data_fim, 'yyyy-MM-dd') AS data_fim,
    try_to_date(v.data_desligamento, 'yyyy-MM-dd') AS vendedor_data_desligamento
  FROM lakehouse_rotaperfume.bronze.carteira c
  LEFT JOIN lakehouse_rotaperfume.bronze.vendedores v
    ON c.vendedor_id = v.vendedor_id
)
SELECT
  carteira_id,
  cliente_id,
  vendedor_id,
  data_inicio,
  data_fim,
  data_fim IS NULL AND vendedor_data_desligamento IS NULL AS vigente,
  data_fim IS NULL AND vendedor_data_desligamento IS NOT NULL AS orfao_vendedor_desligado,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.carteira) AS _linhas_origem
FROM convertido;

COMMENT ON TABLE lakehouse_rotaperfume.silver.carteira IS
  'Vínculo cliente x vendedor. 441 carteiras aparecem vigentes com o vendedor já desligado — o dado não foi corrigido, foi exposto (orfao_vendedor_desligado).';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.carteira.vigente IS
  'TRUE só quando data_fim é NULL E o vendedor não está desligado. Respeita as duas condições — carteira sem data_fim mas de vendedor desligado NÃO é vigente.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.carteira.orfao_vendedor_desligado IS
  'TRUE quando a carteira aparenta estar vigente (sem data_fim) mas o vendedor responsável já foi desligado (441 casos). Problema de processo do CRM, exposto para o gestor em vez de escondido.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.oportunidades AS
SELECT
  oportunidade_id,
  cliente_id,
  vendedor_id,
  origem,
  try_to_date(data_abertura, 'yyyy-MM-dd') AS data_abertura,
  etapa,
  CAST(probabilidade_pct AS INT) AS probabilidade_pct,
  CAST(valor_estimado AS DECIMAL(18, 2)) AS valor_estimado,
  try_to_date(data_fechamento, 'yyyy-MM-dd') AS data_fechamento,
  CAST(ciclo_dias AS INT) AS ciclo_dias,
  motivo_perda,
  -- os valores de origem são 'Fechado ganho' / 'Fechado perdido' — confirmado
  -- com SELECT DISTINCT etapa antes de escrever este CASE.
  etapa = 'Fechado ganho' AS ganha,
  etapa = 'Fechado perdido' AS perdida,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.oportunidades) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.oportunidades;

COMMENT ON TABLE lakehouse_rotaperfume.silver.oportunidades IS
  'Funil comercial tipado, com ganha/perdida derivados de etapa.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.oportunidades.ganha IS
  'Derivado de etapa = ''Fechado ganho'' (na origem, não ''Ganha'').';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.oportunidades.perdida IS
  'Derivado de etapa = ''Fechado perdido'' (na origem, não ''Perdida'').';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.visitas AS
SELECT
  visita_id,
  cliente_id,
  vendedor_id,
  try_to_date(data_visita, 'yyyy-MM-dd') AS data_visita,
  resultado,
  CAST(duracao_min AS INT) AS duracao_min,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.visitas) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.visitas;

COMMENT ON TABLE lakehouse_rotaperfume.silver.visitas IS
  'Visitas comerciais tipadas: data convertida com try_to_date, duração em INT.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pagamentos AS
SELECT
  pagamento_id,
  pedido_id,
  forma_pagamento,
  CAST(parcelas AS INT) AS parcelas,
  CAST(valor AS DECIMAL(18, 2)) AS valor,
  CAST(taxa_pct AS DECIMAL(5, 2)) AS taxa_pct,
  CAST(valor_liquido AS DECIMAL(18, 2)) AS valor_liquido,
  try_to_date(data_vencimento, 'yyyy-MM-dd') AS data_vencimento,
  try_to_date(data_pagamento, 'yyyy-MM-dd') AS data_pagamento,
  status_pagamento,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.pagamentos) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.pagamentos;

COMMENT ON TABLE lakehouse_rotaperfume.silver.pagamentos IS
  'Financeiro tipado: valores em DECIMAL, datas convertidas com try_to_date.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pagamentos.data_pagamento IS
  'NULL quando o pagamento ainda não ocorreu (data vazia na origem) — try_to_date evita que isso quebre a query.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.estoque AS
SELECT
  try_to_date(data_snapshot, 'yyyy-MM-dd') AS data_snapshot,
  sku,
  CAST(saldo AS INT) AS saldo,
  CAST(saldo AS INT) = 0 AS ruptura,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.estoque) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.estoque;

COMMENT ON TABLE lakehouse_rotaperfume.silver.estoque IS
  'Snapshot semanal de saldo por SKU, com ruptura recalculada a partir do próprio saldo em vez de herdar a flag de texto da origem.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.estoque.ruptura IS
  'Derivado de saldo = 0, não copiado do texto S/N da origem — a mesma regra que gera o dado garante a coluna.';
