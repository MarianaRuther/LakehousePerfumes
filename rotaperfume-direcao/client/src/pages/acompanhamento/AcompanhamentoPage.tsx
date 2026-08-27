import {
  useAnalyticsQuery,
  Alert,
  AlertDescription,
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
import { num } from '../../lib/dados';

export function AcompanhamentoPage() {
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

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
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

      {error && (
        <Alert variant="destructive">
          <AlertDescription>Não consegui ler o acompanhamento: {error}</AlertDescription>
        </Alert>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Desfecho por vendedor</CardTitle>
        </CardHeader>
        <CardContent>
          {loading && <Skeleton className="h-40 w-full" />}

          {!loading && !error && semRetorno && (
            <Empty>
              <EmptyTitle>Nenhuma ligação registrada ainda</EmptyTitle>
              <EmptyDescription>
                Zero não é erro: ninguém ligou. Assim que o time marcar o retorno de cada ligação, o número aparece aqui
                — e vira o rótulo de treino da fila da semana que vem.
              </EmptyDescription>
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
