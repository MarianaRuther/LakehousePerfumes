import { useMemo, useState } from 'react';
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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import { sql } from '@databricks/appkit-ui/js';
import { num, reais, pct } from '../../lib/dados';

const TODOS = 'Todos';

function Kpi({
  titulo,
  valor,
  apoio,
  carregando,
}: {
  titulo: string;
  valor: string;
  apoio: string;
  carregando: boolean;
}) {
  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground">{titulo}</CardTitle>
      </CardHeader>
      <CardContent>
        {carregando ? (
          <Skeleton className="h-8 w-24" />
        ) : (
          <div className="text-3xl font-bold text-foreground">{valor}</div>
        )}
        <p className="text-xs text-muted-foreground mt-1">{apoio}</p>
      </CardContent>
    </Card>
  );
}

export function SemanaPage() {
  const [vendedor, setVendedor] = useState<string>(TODOS);

  const kpis = useAnalyticsQuery('kpis_semana');
  const vendedores = useAnalyticsQuery('vendedores');
  const parametrosFila = useMemo(() => ({ vendedor: sql.string(vendedor) }), [vendedor]);
  const fila = useAnalyticsQuery('fila', parametrosFila);

  const k = kpis.data?.[0];
  // Number() no ponto de entrada: o tipo diz number, o JSON entrega string.
  const conversaoPrevista = k ? (num(k.acertos_top200) / num(k.contatos)) * 100 : 0;

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      <div>
        <h2 className="text-2xl font-bold text-foreground">A semana</h2>
        <p className="text-sm text-muted-foreground mt-1">
          Os 200 clientes com maior chance de comprar nos próximos 7 dias
          {k ? ` · fila de ${k.referencia} · modelo versão ${k.versao}` : ''}
        </p>
      </div>

      {kpis.error && (
        <Alert variant="destructive">
          <AlertDescription>Não consegui ler os números da semana: {kpis.error}</AlertDescription>
        </Alert>
      )}

      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Kpi
          titulo="Contatos da semana"
          valor={k ? String(num(k.contatos)) : '—'}
          apoio={k ? `distribuídos em ${num(k.vendedores)} vendedores` : 'carregando'}
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Receita esperada"
          valor={k ? reais(k.receita_esperada) : '—'}
          apoio="soma de score × ticket médio — estimativa, nunca realizada"
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Conversão prevista"
          valor={k ? `${conversaoPrevista.toFixed(0)}%` : '—'}
          apoio={k ? `contra ${(num(k.taxa_base) * 100).toFixed(1)}% ligando às cegas` : 'carregando'}
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Já trabalhados"
          valor={k ? String(num(k.ligacoes_registradas)) : '—'}
          apoio={k ? `${num(k.vendas)} viraram pedido` : 'carregando'}
          carregando={kpis.loading}
        />
      </div>

      <Card>
        <CardHeader className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <CardTitle>Quem ligar primeiro</CardTitle>
          <Select value={vendedor} onValueChange={setVendedor}>
            <SelectTrigger className="w-full sm:w-72">
              <SelectValue placeholder="Todos os vendedores" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={TODOS}>Todos os vendedores</SelectItem>
              {vendedores.data?.map((v) => (
                <SelectItem key={v.vendedor} value={v.vendedor}>
                  {v.vendedor} ({num(v.contatos)})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </CardHeader>
        <CardContent>
          {fila.loading && (
            <div className="space-y-2">
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
            </div>
          )}
          {fila.error && (
            <Alert variant="destructive">
              <AlertDescription>Não consegui ler a fila: {fila.error}</AlertDescription>
            </Alert>
          )}
          {!fila.loading && !fila.error && fila.data?.length === 0 && (
            <Empty>
              <EmptyTitle>Nenhum cliente nesta carteira</EmptyTitle>
              <EmptyDescription>
                A fila é global: são os 200 maiores scores da base inteira, não 200 por vendedor. Quem tem carteira mais
                fria recebe menos contatos — ou nenhum — nesta semana.
              </EmptyDescription>
            </Empty>
          )}
          {!fila.loading && !fila.error && (fila.data?.length ?? 0) > 0 && (
            <div className="overflow-x-auto">
              {/* table-fixed + largura por coluna: sem isso o texto de motivo e
                  sugestão transborda e uma célula escreve por cima da outra. */}
              <Table className="table-fixed w-full min-w-[60rem]">
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-[3rem]">#</TableHead>
                    <TableHead className="w-[16rem]">Cliente</TableHead>
                    <TableHead className="w-[9rem]">Vendedor</TableHead>
                    <TableHead className="w-[5rem] text-right">Chance</TableHead>
                    <TableHead className="w-[17rem]">Por que ligar</TableHead>
                    <TableHead className="w-[15rem]">O que oferecer</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {fila.data?.map((linha, i) => (
                    <TableRow key={num(linha.cliente_id)} className="align-top">
                      {/* Com "Todos", a posição é a da fila global; filtrado por
                          vendedor, é a ordem de ligação daquele vendedor. */}
                      <TableCell className="text-muted-foreground">
                        {vendedor === TODOS ? i + 1 : num(linha.ordem)}
                      </TableCell>
                      <TableCell className="whitespace-normal break-words">
                        <div className="font-medium">{linha.razao_social}</div>
                        <div className="text-xs text-muted-foreground">
                          {linha.cidade}/{linha.uf} · ticket {reais(linha.ticket_medio)}
                        </div>
                      </TableCell>
                      <TableCell className="text-sm whitespace-normal break-words">{linha.vendedor}</TableCell>
                      <TableCell className="text-right font-medium">{pct(linha.score)}</TableCell>
                      <TableCell className="text-sm whitespace-normal break-words">{linha.motivo}</TableCell>
                      <TableCell className="text-sm whitespace-normal break-words">{linha.sugestao}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
