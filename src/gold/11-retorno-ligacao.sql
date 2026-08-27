-- Gold · o retorno da ligação — o caminho de volta
--
-- Esta é a ÚNICA tabela do projeto cujo dado NÃO vem do pipeline. Todas as
-- outras são CREATE OR REPLACE: o job as reconstrói do zero a cada noite. Esta
-- é escrita pelo time comercial (hoje na mão, na noite 4 pelo app) depois que
-- a ligação da fila acontece — vendeu, vai pensar, sem interesse, não atendeu.
--
-- Por isso é CREATE TABLE IF NOT EXISTS, nunca CREATE OR REPLACE: um redeploy
-- ou uma nova execução do job NÃO pode apagar o que o time já respondeu. A
-- tarefa gold_retorno_ligacao roda todo dia junto com o resto, mas depois da
-- primeira vez ela não faz nada — a tabela já existe e o IF NOT EXISTS a
-- protege.
--
-- É também o rótulo de treino da semana seguinte: quem a fila mandou ligar e
-- de fato comprou (status = 'vendeu') é o alvo positivo do próximo modelo.

CREATE TABLE IF NOT EXISTS lakehouse_rotaperfume.gold.retorno_ligacao (
  cliente_id     INT       COMMENT 'Identificador do cliente que foi ligado. Liga com gold.fila_semanal.cliente_id e gold.dim_cliente.cliente_id.',
  vendedor       STRING    COMMENT 'Nome do vendedor que fez a ligação, como em gold.fila_semanal.vendedor / silver.vendedores.nome.',
  status         STRING    COMMENT 'Desfecho da ligação. Um de: vendeu | vai_pensar | sem_interesse | nao_atendeu.',
  comentario     STRING    COMMENT 'Texto livre do vendedor sobre a conversa — objeção, próximo passo, contexto. Pode ser nulo.',
  registrado_em  TIMESTAMP COMMENT 'Momento em que o vendedor registrou o retorno. Para um cliente com mais de um retorno, o mais recente por registrado_em é o que vale.',
  registrado_por STRING    COMMENT 'E-mail de quem estava logado ao registrar o retorno.',
  _referencia    DATE      COMMENT 'A semana da fila (gold.fila_semanal) que originou a ligação — a data de corte das features que geraram o score.'
)
COMMENT 'O que aconteceu depois de cada ligação da fila semanal: vendeu, vai pensar, sem interesse ou não atendeu, com comentário livre do vendedor. Única tabela da gold escrita pelo time comercial, não pelo pipeline (por isso CREATE TABLE IF NOT EXISTS — o job não a sobrescreve). Começa vazia e é o rótulo de treino da semana seguinte.';
