-- @param vendedor STRING = Todos
-- A fila da semana, do maior score para o menor, com todas as colunas de
-- leitura humana (motivo, sugestao) e o último retorno já registrado de cada
-- cliente. 'Todos' devolve os 200; qualquer outro valor filtra por vendedor.
WITH ultimo_retorno AS (
  SELECT cliente_id, status, comentario
  FROM   lakehouse_rotaperfume.gold.retorno_ligacao
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
)
SELECT   f.vendedor,
         f.ordem,
         f.cliente_id,
         f.razao_social,
         f.cidade,
         f.uf,
         f.score,
         f.faixa,
         f.ticket_medio,
         f.motivo,
         f.sugestao,
         r.status     AS retorno_status,
         r.comentario AS retorno_comentario
FROM     lakehouse_rotaperfume.gold.fila_semanal f
LEFT JOIN ultimo_retorno r ON r.cliente_id = f.cliente_id
WHERE    :vendedor = 'Todos' OR f.vendedor = :vendedor
ORDER BY f.score DESC
