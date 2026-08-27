-- Quem tem cliente na fila desta semana. Alimenta o Select da tela "A semana".
-- 35 vendedores; Débora Souza é a de mais contatos.
SELECT   vendedor,
         COUNT(*) AS contatos
FROM     lakehouse_rotaperfume.gold.fila_semanal
GROUP BY vendedor
ORDER BY contatos DESC, vendedor
