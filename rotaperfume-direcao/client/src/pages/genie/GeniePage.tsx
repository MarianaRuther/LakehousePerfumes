import { useEffect, useState } from 'react';
import { Alert, AlertDescription, Badge, GenieChat } from '@databricks/appkit-ui/react';

export function GeniePage() {
  const [email, setEmail] = useState<string>('');

  useEffect(() => {
    let cancelado = false;
    void (async () => {
      try {
        const resposta = await fetch('/api/quem-sou');
        const corpo = (await resposta.json()) as { email?: string };
        if (!cancelado) setEmail(corpo.email ?? '');
      } catch {
        if (!cancelado) setEmail('');
      }
    })();
    return () => {
      cancelado = true;
    };
  }, []);

  return (
    <div className="space-y-4 w-full max-w-4xl mx-auto">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-2xl font-bold text-foreground">Perguntar</h2>
          <p className="text-sm text-muted-foreground mt-1">
            As mesmas tabelas da tela anterior, em português. Pergunte “quanto vale a fila desta semana?” ou “quem são
            os cinco maiores scores?”.
          </p>
        </div>
        {email && <Badge variant="secondary">{email}</Badge>}
      </div>

      {/* Aviso permanente: a resposta é gerada por IA e traz o SQL que a produziu. */}
      <Alert>
        <AlertDescription>
          As respostas são geradas por IA a partir da gold do Rota do Perfume e rodam como o service principal do app.
          Toda resposta traz o SQL que a produziu — confira antes de levar o número para a reunião.
        </AlertDescription>
      </Alert>

      <div className="h-[min(600px,70vh)] border rounded-lg overflow-hidden">
        <GenieChat alias="default" />
      </div>
    </div>
  );
}
