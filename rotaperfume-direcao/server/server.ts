import { createApp, analytics, genie, server } from '@databricks/appkit';

// Prompt 2: o app só LÊ. Toda leitura é um arquivo em config/queries/*.sql —
// nenhuma query mora aqui. A única rota própria é a que diz quem está logado,
// para a aba "Perguntar" mostrar em nome de quem o Genie responde.
await createApp({
  plugins: [analytics(), genie(), server()],

  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      app.get('/api/quem-sou', (req, res) => {
        res.json({
          // No app publicado o Databricks injeta este header; em `npm run dev`
          // não há OAuth, então cai no valor local.
          email: req.header('x-forwarded-email') ?? 'local@rotaperfume',
          usuario: req.header('x-forwarded-user') ?? 'desenvolvimento',
        });
      });
    });
  },
});
