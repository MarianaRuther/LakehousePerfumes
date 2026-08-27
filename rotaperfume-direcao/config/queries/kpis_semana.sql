-- Os quatro números que o diretor olha antes de qualquer tabela: o tamanho e o
-- valor da fila desta semana, a métrica do modelo que a gerou, e o retorno já
-- registrado pelo time (que no começo da semana é zero).
WITH fila AS (
  SELECT COUNT(*)                  AS contatos,
         COUNT(DISTINCT vendedor)  AS vendedores,
         SUM(score * ticket_medio) AS receita_esperada,
         -- gold.fila_semanal não carrega a data de corte; o "hoje" do dataset
         -- é fixo (seed 42, sem current_date()).
         DATE '2026-08-31'         AS referencia
  FROM   lakehouse_rotaperfume.gold.fila_semanal
),
-- A última versão do modelo — a que gerou a fila que está no ar.
modelo AS (
  SELECT acertos_top200, lift_top200, taxa_base, versao
  FROM   lakehouse_rotaperfume.gold.modelo_metricas
  QUALIFY ROW_NUMBER() OVER (ORDER BY versao DESC) = 1
),
retorno AS (
  SELECT COUNT(*)                    AS ligacoes_registradas,
         COUNT_IF(status = 'vendeu') AS vendas
  FROM   lakehouse_rotaperfume.gold.retorno_ligacao
)
SELECT fila.contatos,
       fila.vendedores,
       fila.receita_esperada,
       fila.referencia,
       modelo.acertos_top200,
       modelo.lift_top200,
       modelo.taxa_base,
       modelo.versao,
       retorno.ligacoes_registradas,
       retorno.vendas
FROM   fila, modelo, retorno
