// Recebe webhook de provedor e transforma em message_events.
//
// Um endpoint por CHIP, não por provedor: /canal-webhook/<webhook_token>.
// Antes era por provedor, e por isso quem recebia não sabia de qual conta o
// evento vinha — sem conta não há tenant, e sem tenant não dá para casar uma
// resposta pelo número. Era o que deixava a invariante 4 sem valer no canal
// não oficial (D23).
//
// O token é a credencial: aleatório de 128 bits, um por conta, e é ele que
// diz chip, tenant e provedor. Token desconhecido responde 404 e não diz mais
// nada — enumerar chip não pode ser mais fácil do que adivinhar um uuid.
//
// Responde 200 mesmo quando nada casa: provedor que recebe erro reenfileira e
// reenvia, e um id desconhecido não melhora na segunda tentativa.

import { bancoSupabase, clienteAdmin, resolverWebhook } from '../_shared/banco-supabase.ts';
import { receberWebhook } from '../../../motor/webhooks.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  const token = new URL(req.url).pathname.split('/').filter(Boolean).pop() ?? '';

  if (!UUID.test(token)) {
    return Response.json({ ok: false, erro: 'token ausente' }, { status: 404 });
  }

  try {
    const sb = clienteAdmin();
    const chip = await resolverWebhook(sb, token);
    if (!chip) {
      return Response.json({ ok: false, erro: 'token desconhecido' }, { status: 404 });
    }

    const corpo = await req.json().catch(() => ({}));
    const resumo = await receberWebhook(bancoSupabase(sb), chip.provedor, corpo, {
      senderId: chip.sender_id,
    });

    return Response.json({ ok: true, provedor: chip.provedor, ...resumo });
  } catch (e) {
    console.error('[canal-webhook]', e);
    return Response.json(
      { ok: false, erro: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
});
