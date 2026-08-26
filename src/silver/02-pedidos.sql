-- Silver · pedidos
--
-- valor_total vem como texto, data_pedido nos dois formatos (ISO e
-- dd/MM/yyyy), e pedido cancelado tem valor zerado no ERP sem nenhuma flag
-- explícita — só o status conta a história.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pedidos AS
WITH convertido AS (
  SELECT
    pedido_id,
    cliente_id,
    vendedor_id,
    coalesce(
      try_to_date(data_pedido, 'yyyy-MM-dd'),
      try_to_date(data_pedido, 'dd/MM/yyyy')
    ) AS data_pedido,
    canal,
    status,
    CAST(valor_total AS DECIMAL(18, 2)) AS valor_total
  FROM lakehouse_rotaperfume.bronze.pedidos
)
SELECT
  pedido_id,
  cliente_id,
  vendedor_id,
  data_pedido,
  canal,
  status,
  valor_total,
  status = 'Cancelado' AS cancelado,
  -- 135 pedidos têm valor_total negativo por causa de item devolvido dentro
  -- deles: negócio legítimo, não sujeira. A regra de zerar é só para
  -- cancelado — por isso NÃO é `valor_liquido >= 0`.
  CASE WHEN status = 'Cancelado' THEN 0 ELSE valor_total END AS valor_liquido,
  year(data_pedido) AS ano,
  month(data_pedido) AS mes,
  current_timestamp() AS _processado_em,
  (SELECT count(*) FROM lakehouse_rotaperfume.bronze.pedidos) AS _linhas_origem
FROM convertido;

COMMENT ON TABLE lakehouse_rotaperfume.silver.pedidos IS
  'Cabeçalho de pedido limpo: valor tipado, data convertida e cancelamento explicitado em cancelado/valor_liquido (957 pedidos cancelados).';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.data_pedido IS
  'Convertida com try_to_date (ANSI mode aborta com to_date em data malformada): ISO e dd/MM/yyyy misturados na origem, resolvidos com coalesce dos dois formatos.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.valor_total IS
  'Texto convertido para DECIMAL(18,2). Pode ser negativo em pedido com item devolvido — não é erro.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.cancelado IS
  'Derivado de status = ''Cancelado''. O ERP não trazia essa flag — só o texto do status.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.valor_liquido IS
  'Zero quando cancelado, valor_total caso contrário. Pedido não cancelado pode ficar negativo (devolução) — comportamento esperado, não filtrado aqui.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.ano IS
  'Extraído de data_pedido para facilitar agregação por período.';

COMMENT ON COLUMN lakehouse_rotaperfume.silver.pedidos.mes IS
  'Extraído de data_pedido para facilitar agregação por período. Sazonalidade é invertida: o pico da distribuidora é o mês anterior à data comemorativa.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT pedidos_data_pedido_nao_nula CHECK (data_pedido IS NOT NULL);

-- A constraint intuitiva seria `valor_liquido >= 0` — e ela FALHARIA: 135
-- pedidos legítimos têm valor negativo por devolução. A regra certa é sobre
-- cancelamento, não sobre sinal.
ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT pedidos_cancelado_valor_zero CHECK (NOT cancelado OR valor_liquido = 0);
