import { createApp, analytics, genie, server, getExecutionContext } from '@databricks/appkit';
import { z } from 'zod';

// Prompt 3: o app agora ESCREVE — mas por um caminho só. Toda leitura continua
// sendo um arquivo em config/queries/*.sql; a escrita é esta única rota POST,
// com o conjunto de valores fechado por Zod. Se o front pudesse mandar `status`
// livre, em três semanas a tabela teria "vendeu", "Vendeu" e "vendido".
const RetornoSchema = z.object({
  // O warehouse serializa id como string mesmo tipado como number: a tela manda
  // "2137", e z.coerce.number() aceita e converte antes do .int().
  cliente_id: z.coerce.number().int(),
  vendedor: z.string().min(1),
  // O enum é o contrato. Qualquer outro desfecho é recusado com 400, sem tocar
  // no warehouse — o retorno de hoje é o rótulo de treino da semana que vem.
  status: z.enum(['vendeu', 'vai_pensar', 'sem_interesse', 'nao_atendeu']),
  comentario: z.string().max(500).default(''),
  referencia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'referência deve ser aaaa-mm-dd'),
});

await createApp({
  plugins: [analytics(), genie(), server()],

  // Sem cache de leitura. Toda tela lê a fila da semana e o retorno que o time
  // acabou de registrar: servir resposta guardada é mostrar número velho para
  // quem acabou de clicar. São 200 linhas — o warehouse aguenta pedir de novo.
  cache: { enabled: false },

  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      // Quem está logado. No app publicado o Databricks injeta este header; em
      // `npm run dev` não há OAuth, então cai no valor local.
      app.get('/api/quem-sou', (req, res) => {
        res.json({
          email: req.header('x-forwarded-email') ?? 'local@rotaperfume',
          usuario: req.header('x-forwarded-user') ?? 'desenvolvimento',
        });
      });

      // A ÚNICA rota que escreve. Corpo inválido devolve 400 ANTES de consultar
      // o warehouse.
      app.post('/api/retorno', async (req, res) => {
        const parsed = RetornoSchema.safeParse(req.body);
        if (!parsed.success) {
          res.status(400).json({
            erro: 'Retorno inválido',
            detalhe: parsed.error.issues,
          });
          return;
        }

        const { cliente_id, vendedor, status, comentario, referencia } = parsed.data;
        // registrado_por vem do header, não do corpo: quem clicou é quem grava.
        const email = req.header('x-forwarded-email') ?? 'local@rotaperfume';

        try {
          const contexto = getExecutionContext();
          const warehouseId = (await contexto.warehouseId) ?? process.env.DATABRICKS_WAREHOUSE_ID!;

          // TODO valor vai por `parameters` — nunca concatenado na string do SQL.
          await contexto.client.statementExecution.executeStatement({
            warehouse_id: warehouseId,
            wait_timeout: '30s',
            statement: `
              INSERT INTO lakehouse_rotaperfume.gold.retorno_ligacao
                (cliente_id, vendedor, status, comentario, registrado_em, registrado_por, _referencia)
              VALUES
                (:cliente_id, :vendedor, :status, :comentario, current_timestamp(), :email, :referencia)
            `,
            parameters: [
              { name: 'cliente_id', value: String(cliente_id), type: 'INT' },
              { name: 'vendedor', value: vendedor, type: 'STRING' },
              { name: 'status', value: status, type: 'STRING' },
              { name: 'comentario', value: comentario, type: 'STRING' },
              { name: 'email', value: email, type: 'STRING' },
              { name: 'referencia', value: referencia, type: 'DATE' },
            ],
          });

          res.status(201).json({ ok: true });
        } catch (erro) {
          console.error('[retorno] falhou ao gravar', erro);
          res.status(500).json({ erro: 'Não consegui gravar o retorno' });
        }
      });
    });
  },
});
