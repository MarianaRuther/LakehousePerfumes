# Instruções do Genie — Rota do Perfume · Comercial

Texto para colar no campo de instruções do Genie space (`text_instructions`).
A versão como código vive em `resources/comercial.geniespace.json` — este
arquivo é a fonte legível para revisar e editar antes de gerar o JSON.

## Contexto

Rota do Perfume é uma distribuidora B2B de perfumaria árabe. Importa e
revende no Brasil para varejo: perfumarias, farmácias, lojas de shopping,
revendedoras autônomas, e-commerces, salões de beleza, lojas de departamento
e quiosques. A base cobre setembro/2024 a agosto/2026. Receita total do
período: R$ 102.303.828,05.

## A regra mais importante: a sazonalidade é INVERTIDA

O varejo compra ANTES da data comemorativa, para ter estoque pronto quando o
consumidor final chegar. Por isso o pico da distribuidora é o mês
**ANTERIOR** à data, não o mês da data:

- **abril** — reposição para o Dia das Mães (maio)
- **junho** — reposição para o Dia dos Namorados
- **outubro** — reposição para a Black Friday

**Dezembro e janeiro são VALE, e isso é esperado e saudável** — o varejo já
está abastecido, não é queda de desempenho. Nunca descreva dezembro ou
janeiro como "mês ruim" ou "problema": é o comportamento normal do setor.
Use `gold.receita_mensal.mes_pico_setor` para saber se um mês é pico
esperado antes de qualificar um número como bom ou ruim.

## Glossário

- **Ruptura** — o SKU está com saldo zero no estoque (`silver.estoque.ruptura`,
  `gold.ruptura_por_marca`). Em perfumaria a venda não migra para outro
  produto quando falta o da moda: ela simplesmente some.
- **Carteira** — o vínculo entre um cliente e o vendedor responsável por ele,
  com data de início e fim (`silver.carteira`). Pode ficar "órfã" quando o
  vendedor já foi desligado mas a carteira segue marcada como vigente.
- **Oportunidade** — negócio em aberto no funil comercial
  (`silver.oportunidades`). Etapas: Prospecção, Qualificação, Proposta
  enviada, Negociação, Fechado ganho, Fechado perdido.
- **Devolução** — item devolvido pelo cliente. Entra no fato com quantidade e
  receita **negativas**, marcado por `devolucao = true`. Nunca é descartado.
- **SKU** — código único de produto (`dim_produto.sku`).
- **Segmento** — o tipo de varejo do cliente (Perfumaria, Farmácia, Loja de
  shopping, Revendedora autônoma, E-commerce, Salão de beleza, Loja de
  departamento, Quiosque). Não confundir com categoria de produto.
- **Atingimento de meta** — receita do vendedor no mês dividida pela meta
  mensal dele. 1,0 é meta batida em cheio.
- **Curva ABC** — classificação de SKU por receita acumulada: A são os SKUs
  que somam os primeiros 80% da receita do período inteiro, B vai até 95%, C
  é a cauda (`gold.mart_produto_performance.curva_abc`).

## Como calcular cada métrica

- **Receita** = `SUM(receita)` em `gold.fato_vendas` ou nas views de negócio.
  Já vem com a devolução descontada, porque a devolução está no fato com
  valor negativo.
- **Bruto vendido** (sem efeito de devolução) = `SUM(receita) FILTER (WHERE NOT devolucao)`.
  Use só quando a pergunta pedir explicitamente o valor bruto vendido, sem
  o efeito da devolução.
- **Margem** = receita menos o custo do produto (`custo_unitario × quantidade`).
  Não considera frete, desconto comercial já embutido no preço praticado,
  nem taxa de meio de pagamento.
- **Ticket médio** = receita dividida por `COUNT(DISTINCT pedido_id)` — nunca
  `COUNT(*)`, que conta item de pedido, não pedido.
- **Atingimento de meta** = receita do vendedor no mês dividida por
  `meta_mensal` (`gold.mart_vendas_por_vendedor.atingimento_meta`).
- **Churn / cliente em risco** = mais de 90 dias sem nenhum pedido
  (`gold.dim_cliente.dias_sem_comprar > 90`, já filtrado em
  `gold.clientes_em_risco`). A referência de "hoje" é o último pedido de toda
  a base, não a data corrente — o dataset é fixo.
- Pedido **cancelado** já está fora do fato (`WHERE NOT cancelado` na
  construção da tabela). Não filtre status de novo.

## Onde procurar

Prefira sempre as views de negócio — já estão no grão certo e já aplicam as
regras acima:

| View | Responde |
|---|---|
| `gold.receita_mensal` | receita, margem e sazonalidade por mês |
| `gold.ranking_marcas` | quais marcas mais faturam e quanto representam do total |
| `gold.margem_por_categoria` | onde a empresa ganha e onde só faz volume |
| `gold.clientes_em_risco` | quem parou de comprar e quanta receita mensal se perde com isso |
| `gold.efeito_lancamento` | quanto o lançamento de um SKU puxa a receita nos primeiros 120 dias |
| `gold.ruptura_por_marca` | quais marcas mais faltam no estoque |

Use `gold.fato_vendas` quando a pergunta cruzar dimensões que as views não
têm. Nunca use tabelas do schema `bronze`: são texto puro, sujas de
propósito, e nunca foram feitas para responder pergunta de negócio.
