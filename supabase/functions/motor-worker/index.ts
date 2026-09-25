// Worker do motor. Acorda, pergunta quem está vencido, despacha o que houver.
//
// Chamado por pg_cron. Fino de propósito: toda decisão está em `motor/` e no
// SQL, que têm teste. Aqui só há fiação.
//
// Modo vem do corpo da requisição, com 'simulado' como padrão — durante a
// Fase 3 nenhuma chamada precisa se lembrar de pedir shadow mode, e ligar o
// envio real é uma mudança explícita no agendamento do cron.

import { bancoSupabase, clienteAdmin } from '../_shared/banco-supabase.ts';
import { umaPassada } from '../../../motor/despachante.ts';

Deno.serve(async (req) => {
  try {
    const corpo = await req.json().catch(() => ({}));
    const modo = corpo?.modo === 'real' ? 'real' : 'simulado';
    const limite = Number(corpo?.limite) || 100;

    const resultado = await umaPassada(bancoSupabase(clienteAdmin()), modo, { limite });

    return Response.json({ ok: true, modo, ...resultado });
  } catch (e) {
    console.error('[motor-worker]', e);
    return Response.json(
      { ok: false, erro: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
});
