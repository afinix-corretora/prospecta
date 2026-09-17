// Recebe webhook de provedor e transforma em message_events.
//
// Um endpoint por provedor: /canal-webhook/evolution, /canal-webhook/meta_cloud.
// O legado tinha sete normalizadores separados; aqui a normalização é método
// do adapter e esta função não conhece nenhum formato.
//
// Responde 200 mesmo quando nada casa: provedor que recebe erro reenfileira e
// reenvia, e um id desconhecido não melhora na segunda tentativa.

import { bancoSupabase, clienteAdmin } from '../_shared/banco-supabase.ts';
import { receberWebhook } from '../../../motor/webhooks.ts';

Deno.serve(async (req) => {
  const provedor = new URL(req.url).pathname.split('/').filter(Boolean).pop() ?? '';

  try {
    const corpo = await req.json().catch(() => ({}));
    const resumo = await receberWebhook(bancoSupabase(clienteAdmin()), provedor, corpo);
    return Response.json({ ok: true, provedor, ...resumo });
  } catch (e) {
    console.error('[canal-webhook]', provedor, e);
    return Response.json(
      { ok: false, provedor, erro: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
});
