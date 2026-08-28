/**
 * Utilidades de formatação compartilhadas pelas telas.
 *
 * O warehouse serializa TODO número como string no JSON, mesmo quando o tipo
 * gerado pelo typegen diz `number`. O compilador não reclama e o estrago
 * aparece na tela: `toLocaleString` devolve a string intacta (R$ some e
 * aparece 582799.4988012867) e `+` concatena ("7" + "12" vira "712"). Por isso
 * tudo aqui passa por Number() antes de qualquer conta ou formatação.
 */

export const num = (v: number | string | null | undefined): number => Number(v ?? 0);

export const reais = (v: number | string): string =>
  num(v).toLocaleString('pt-BR', {
    style: 'currency',
    currency: 'BRL',
    maximumFractionDigits: 0,
  });

/** Score de 0 a 1 vira porcentagem inteira: ninguém decide ligação lendo 0,974. */
export const pct = (v: number | string, casas = 0): string => `${(num(v) * 100).toFixed(casas)}%`;

/**
 * Os quatro desfechos possíveis de uma ligação, na ordem em que o vendedor
 * pensa neles. É a mesma lista do `enum` no servidor — botão é interface, o
 * enum é o contrato, e os dois precisam bater.
 */
export const STATUS = [
  { valor: 'vendeu', rotulo: 'Vendeu', bom: true },
  { valor: 'vai_pensar', rotulo: 'Vai pensar', bom: false },
  { valor: 'sem_interesse', rotulo: 'Sem interesse', bom: false },
  { valor: 'nao_atendeu', rotulo: 'Não atendeu', bom: false },
] as const;

/** Rótulo em português de um dos quatro desfechos de uma ligação. */
export const rotuloStatus = (valor: string): string => STATUS.find((s) => s.valor === valor)?.rotulo ?? valor;
