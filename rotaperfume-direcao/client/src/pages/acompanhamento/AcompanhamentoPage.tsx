import { useState } from 'react';
import {
  useAnalyticsQuery,
  Alert,
  AlertDescription,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Empty,
  EmptyDescription,
  EmptyTitle,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import { RefreshCw } from 'lucide-react';
import { num } from '../../lib/dados';

/**
 * A tela é remontada pela `key` do pai a cada "Atualizar" — remontar refaz a
 * consulta. É o jeito React de recarregar, sem parâmetro inventado no SQL só
 * para furar cache (que quebra a tela de quem está com o JS antigo aberto).
 */
function Conteudo({ aoAtualizar }: { aoAtualizar: () => void }) {
  const { data, loading, error } = useAnalyticsQuery('acompanhamento');

  const total = (data ?? []).reduce(
    (acc, l) => ({
      na_fila: acc.na_fila + num(l.na_fila),
      trabalhados: acc.trabalhados + num(l.trabalhados),
      vendeu: acc.vendeu + num(l.vendeu),
    }),
    { na_fila: 0, trabalhados: 0, vendeu: 0 }
  );
  const semRetorno = total.trabalhados === 0;

  // O gráfico só mostra quem já ligou: 35 linhas zeradas escondem as poucas que
  // importam. A escala das barras é o maior número de contatos na fila de um
  // vendedor, para todas as barras serem comparáveis entre si.
  const trabalharam = (data ?? [])
    .map((l) => ({
      vendedor: l.vendedor,
      na_fila: num(l.na_fila),
      trabalhados: num(l.trabalhados),
      vendeu: num(l.vendeu),
    }))
    .filter((l) => l.trabalhados > 0);
  const escala = Math.max(1, ...trabalharam.map((l) => l.na_fila));

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-2xl font-bold text-foreground">
            {loading
              ? 'Acompanhamento'
              : semRetorno
                ? 'A semana ainda não começou a ser trabalhada'
                : `${total.trabalhados} de ${total.na_fila} contatos trabalhados · ${total.vendeu} viraram pedido`}
          </h2>
          <p className="text-sm text-muted-foreground mt-1">O que a fila desta semana virou, vendedor por vendedor</p>
        </div>
        <Button variant="outline" size="sm" onClick={aoAtualizar}>
          <RefreshCw className="h-4 w-4 mr-2" />
          Atualizar
        </Button>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>Não consegui ler o acompanhamento: {error}</AlertDescription>
        </Alert>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Contatos trabalhados por vendedor</CardTitle>
        </CardHeader>
        <CardContent>
          {loading && <Skeleton className="h-48 w-full" />}

          {!loading && !error && semRetorno && (
            <Empty>
              <EmptyTitle>Nenhuma ligação registrada ainda</EmptyTitle>
              <EmptyDescription>
                Zero não é erro: ninguém ligou. Assim que o time marcar o retorno na aba “A semana”, o número aparece
                aqui — e vira o rótulo de treino da fila da semana que vem.
              </EmptyDescription>
            </Empty>
          )}

          {!loading && !error && !semRetorno && (
            <div className="space-y-4">
              {trabalharam.map((l) => (
                <div key={l.vendedor} className="space-y-1.5">
                  <div className="flex items-baseline justify-between gap-4 text-sm">
                    <span className="font-medium">{l.vendedor}</span>
                    <span className="text-muted-foreground">
                      {l.trabalhados} de {l.na_fila} trabalhados ·{' '}
                      <span className="text-foreground font-medium">{l.vendeu} vendeu</span>
                    </span>
                  </div>
                  {/* Duas barras sobrepostas: a clara é o quanto da fila daquele
                      vendedor foi trabalhado; a escura, o que virou pedido. */}
                  <div className="relative h-3 w-full rounded-full bg-muted overflow-hidden">
                    <div
                      className="absolute inset-y-0 left-0 bg-muted-foreground/40"
                      style={{ width: `${(l.trabalhados / escala) * 100}%` }}
                    />
                    <div
                      className="absolute inset-y-0 left-0 bg-primary"
                      style={{ width: `${(l.vendeu / escala) * 100}%` }}
                    />
                  </div>
                </div>
              ))}
              <p className="text-xs text-muted-foreground pt-2">
                Barra clara: contatos trabalhados. Barra escura: os que viraram pedido. Quem ainda não ligou não aparece
                aqui — está na tabela abaixo.
              </p>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Desfecho por vendedor</CardTitle>
        </CardHeader>
        <CardContent>
          {loading && <Skeleton className="h-40 w-full" />}

          {!loading && !error && semRetorno && (
            <Empty>
              <EmptyTitle>Ainda sem desfecho</EmptyTitle>
              <EmptyDescription>A tabela preenche assim que o primeiro retorno for registrado.</EmptyDescription>
            </Empty>
          )}

          {!loading && !error && !semRetorno && (
            <div className="overflow-x-auto">
              <Table className="table-fixed w-full min-w-[52rem]">
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-[14rem]">Vendedor</TableHead>
                    <TableHead className="w-[6rem] text-right">Na fila</TableHead>
                    <TableHead className="w-[7rem] text-right">Trabalhados</TableHead>
                    <TableHead className="w-[6rem] text-right">Vendeu</TableHead>
                    <TableHead className="w-[7rem] text-right">Vai pensar</TableHead>
                    <TableHead className="w-[8rem] text-right">Sem interesse</TableHead>
                    <TableHead className="w-[8rem] text-right">Não atendeu</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {data?.map((l) => {
                    const trabalhou = num(l.trabalhados) > 0;
                    return (
                      <TableRow key={l.vendedor} className={trabalhou ? '' : 'text-muted-foreground'}>
                        <TableCell className="font-medium">{l.vendedor}</TableCell>
                        <TableCell className="text-right">{num(l.na_fila)}</TableCell>
                        <TableCell className="text-right font-medium">{num(l.trabalhados)}</TableCell>
                        <TableCell className="text-right font-medium">{num(l.vendeu)}</TableCell>
                        <TableCell className="text-right">{num(l.vai_pensar)}</TableCell>
                        <TableCell className="text-right">{num(l.sem_interesse)}</TableCell>
                        <TableCell className="text-right">{num(l.nao_atendeu)}</TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

export function AcompanhamentoPage() {
  // Trocar a key remonta a tela inteira, e a consulta roda de novo.
  const [visita, setVisita] = useState(0);
  return <Conteudo key={visita} aoAtualizar={() => setVisita((n) => n + 1)} />;
}
