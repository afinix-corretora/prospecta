// Worker do motor. Acorda, pergunta quem está vencido, despacha o que houver.
//
// Chamado por pg_cron. Fino de propósito: toda decisão está em `motor/` e no
// SQL, que têm teste. Aqui só há fiação.
//
// Modo vem do corpo da requisição, com 'simulado' como padrão — durante a
// Fase 3 nenhuma chamada precisa se lembrar de pedir shadow mode, e ligar o
// envio real é uma mudança explícita no agendamento do cron.
//
// Desde o D64 a passada tem três partes: a cadência (agendador e despacho),
// o dreno da outbox para o CRM e a leitura das fontes de CRM. Cada uma com o
// seu `try`: CRM fora do ar não pode parar a cadência, e a cadência quebrada
// não pode prender os fatos que já existem. O modo não chega às duas do CRM
// de propósito — shadow mode é decidido onde o fato nasce (D45), e ler um CRM
// não é efeito externo.
//
// Desde o D66, uma quarta: os rascunhos do agente, com o seu `try`. Desde o
// D69 ela leva o modo: o rascunho pronto de agente autônomo vira mensagem, e
// em shadow mode ela nasce simulada como a cadência. Ela roda DEPOIS do
// despacho de propósito — compor chama modelo e demora, e a cadência não pode
// esperar por isso. A resposta do agente sai no despacho da passada seguinte.

import { bancoSupabase, clienteAdmin } from '../_shared/banco-supabase.ts';
import { bancoCrmSupabase } from '../_shared/banco-crm.ts';
import { umaPassada } from '../../../motor/despachante.ts';
import { drenarWritebacks, lerFontes } from '../../../motor/crm.ts';
import { bancoAgenteSupabase } from '../_shared/banco-agente.ts';
import { rascunharRespostas } from '../../../motor/agente.ts';

const erro = (e: unknown) => (e instanceof Error ? e.message : String(e));

Deno.serve(async (req) => {
  const corpo = await req.json().catch(() => ({}));
  const modo = corpo?.modo === 'real' ? 'real' : 'simulado';
  const limite = Number(corpo?.limite) || 100;
  const sb = clienteAdmin();
  const falhas: string[] = [];

  let cadencia: unknown = null;
  try {
    cadencia = await umaPassada(bancoSupabase(sb), modo, { limite });
  } catch (e) {
    console.error('[motor-worker] cadência', e);
    falhas.push(`cadência: ${erro(e)}`);
  }

  let writeback: unknown = null;
  try {
    writeback = await drenarWritebacks(bancoCrmSupabase(sb), 50);
  } catch (e) {
    console.error('[motor-worker] writeback', e);
    falhas.push(`writeback: ${erro(e)}`);
  }

  let fontes: unknown = null;
  try {
    fontes = await lerFontes(bancoCrmSupabase(sb));
  } catch (e) {
    console.error('[motor-worker] fontes', e);
    falhas.push(`fontes: ${erro(e)}`);
  }

  let rascunhos: unknown = null;
  try {
    rascunhos = await rascunharRespostas(bancoAgenteSupabase(sb), 20, { modo });
  } catch (e) {
    console.error('[motor-worker] rascunhos', e);
    falhas.push(`rascunhos: ${erro(e)}`);
  }

  // 500 quando qualquer parte falhou: o `net._http_response` do pg_cron é o
  // único lugar onde passada quebrada aparece, e 200 com erro dentro seria a
  // passada 401 do D44 com outra cara.
  const ok = falhas.length === 0;
  const resto = (cadencia ?? {}) as Record<string, unknown>;
  return Response.json({ ok, modo, ...resto, writeback, fontes, rascunhos, ...(ok ? {} : { erro: falhas.join(' | ') }) },
    { status: ok ? 200 : 500 });
});
