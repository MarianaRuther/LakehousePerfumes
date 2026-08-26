-- Silver · clientes
--
-- A bronze traz cliente_id, cnpj (três formatos: puro, pontuado e com espaço
-- em volta), razao_social (caixa e espaçamento inconsistentes), data_cadastro
-- (ISO e dd/MM/yyyy misturados) e 40 CNPJs que aparecem com dois cliente_id —
-- cadastro duplicado. Esta tabela resolve os quatro problemas.
--
-- ANSI mode está ligado neste workspace: to_date() sobre data malformada
-- ABORTA a query. Por isso toda conversão de data usa try_to_date().

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.clientes AS
WITH normalizado AS (
  SELECT
    cliente_id,
    -- trim -> tira tudo que não é dígito -> completa com zero à esquerda até
    -- 14. Nunca via CAST para número: isso apagaria zero à esquerda de novo.
    lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0') AS cnpj,
    initcap(regexp_replace(trim(razao_social), ' +', ' ')) AS razao_social,
    segmento,
    cidade,
    uf,
    bairro,
    coalesce(
      try_to_date(data_cadastro, 'yyyy-MM-dd'),
      try_to_date(data_cadastro, 'dd/MM/yyyy')
    ) AS data_cadastro,
    ativo = 'S' AS ativo
  FROM lakehouse_rotaperfume.bronze.clientes
),
deduplicado AS (
  SELECT
    *,
    -- 40 CNPJs têm dois cliente_id: fica o cadastro MAIS ANTIGO.
    row_number() OVER (
      PARTITION BY cnpj ORDER BY data_cadastro ASC, cliente_id ASC
    ) AS ordem_cadastro,
    -- ids descartados do mesmo CNPJ, guardados no id que sobrevive — pedidos
    -- antigos apontam para eles, e sem isso a referência se perde.
    array_except(
      collect_set(cliente_id) OVER (PARTITION BY cnpj),
      array(cliente_id)
    ) AS cliente_ids_duplicados
  FROM normalizado
)
SELECT
  cliente_id,
  cnpj,
  razao_social,
  segmento,
  cidade,
  uf,
  bairro,
  data_cadastro,
  ativo,
  cliente_ids_duplicados,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.clientes) AS _linhas_origem
FROM deduplicado
WHERE ordem_cadastro = 1;

COMMENT ON TABLE lakehouse_rotaperfume.silver.clientes IS
  'Cadastro de clientes limpo: CNPJ normalizado para 14 dígitos, razão social padronizada, data de cadastro convertida e os 40 CNPJs duplicados resolvidos mantendo o cadastro mais antigo (3.000 clientes únicos no final).';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.cnpj IS
  'Normalizado para 14 dígitos: trim, regexp_replace removendo tudo que não é dígito, lpad com zero à esquerda. Nunca convertido para número — perderia zero à esquerda.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.razao_social IS
  'Caixa e espaçamento padronizados com initcap e colapso de espaço duplo.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.data_cadastro IS
  'Convertida com try_to_date (ANSI mode aborta com to_date em data malformada): ISO e dd/MM/yyyy misturados na origem, resolvidos com coalesce dos dois formatos.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.ativo IS
  'Convertido de texto (S/N) para boolean.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.clientes.cliente_ids_duplicados IS
  'cliente_id descartados no mesmo CNPJ (40 casos) — pedidos antigos ainda apontam para esses ids, guardados aqui para rastreabilidade.';

ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT clientes_cnpj_14_digitos CHECK (length(cnpj) = 14);

ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT clientes_data_cadastro_nao_nula CHECK (data_cadastro IS NOT NULL);
