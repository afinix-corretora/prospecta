// Testes do despachante e da recepção de webhook.
//
// Banco e adapters são falsos: aqui se testa a costura, não o provedor nem o
// SQL. O provedor tem tests/adapters.test.ts; o SQL tem tests/despacho.sql.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import type { Banco, Culpa, MensagemParaEnviar } from '../motor/porta.ts';
import type { ChannelAdapter, EventoNormalizado, ResultadoEnvio } from '../adapters/tipos.ts';
import { despachar, umaPassada } from '../motor/despachante.ts';
import { receberWebhook } from '../motor/webhooks.ts';

interface Registro {
  messageId: string; ok: boolean; providerMessageId?: string; erro?: string; culpa?: Culpa;
}

function bancoFalso(pendentes: MensagemParaEnviar[], opcoes: {
  provedor?: string;
  credenciais?: Record<string, string>;
  erroCredencial?: string;
  erroAoRegistrar?: string;
  eventoAceito?: (id: string) => boolean;
} = {}) {
  const registros: Registro[] = [];
  const eventos: { id: string; tipo: string }[] = [];
  let agendadas = 0;

  const banco: Banco = {
    async processarVencidos(_limite, _modo) { agendadas += 1; return 7; },
    async reivindicarPendentes() { return pendentes; },
    async credenciaisDoRemetente() {
      if (opcoes.erroCredencial) throw new Error(opcoes.erroCredencial);
      return {
        provedor: opcoes.provedor ?? 'falso',
        credenciais: opcoes.credenciais ?? {},
      };
    },
    async registrarResultado(messageId, ok, providerMessageId, erro, culpa) {
      if (opcoes.erroAoRegistrar) throw new Error(opcoes.erroAoRegistrar);
      registros.push({ messageId, ok, providerMessageId, erro, culpa });
    },
    async registrarEventoProvedor(providerMessageId, tipo) {
      eventos.push({ id: providerMessageId, tipo });
      return opcoes.eventoAceito ? opcoes.eventoAceito(providerMessageId) : true;
    },
  };

  return { banco, registros, eventos, chamadasAgendador: () => agendadas };
}

function adapterFalso(canal: string, resposta: ResultadoEnvio | (() => ResultadoEnvio),
                      eventos: EventoNormalizado[] = []) {
  const enviados: unknown[] = [];
  const adapter = {
    canal,
    provedor: 'falso',
    async send(pedido: unknown) {
      enviados.push(pedido);
      return typeof resposta === 'function' ? resposta() : resposta;
    },
    normalizeWebhook() { return eventos; },
    async checkHealth() { return { ok: true, detalhe: '' }; },
  } as unknown as ChannelAdapter;
  return { criar: () => adapter, enviados };
}

function mensagem(over: Partial<MensagemParaEnviar> = {}): MensagemParaEnviar {
  return {
    message_id: 'm-1', canal: 'whatsapp', destino: '+5511900000001',
    conteudo: 'Oi', sender_id: 's-1', sender_ident: 'instancia-a',
    campanha_tipo: 'morna', ...over,
  };
}

// ---------------------------------------------------------------------------
// Despacho
// ---------------------------------------------------------------------------

test('despacha o que foi reivindicado e registra sucesso', async () => {
  const { banco, registros } = bancoFalso([mensagem()]);
  const { criar, enviados } = adapterFalso('whatsapp', { ok: true, providerMessageId: 'P1' });

  const r = await despachar(banco, { criar: criar as never });

  assert.deepEqual(r, {
    reivindicadas: 1, enviadas: 1, falhas: 0,
    porCulpa: { remetente: 0, destino: 0, transitorio: 0 },
  });
  assert.equal(enviados.length, 1);
  assert.deepEqual(registros, [
    { messageId: 'm-1', ok: true, providerMessageId: 'P1', erro: undefined, culpa: 'transitorio' },
  ]);
});

test('o adapter recebe destino, conteúdo, remetente e credenciais', async () => {
  const { banco } = bancoFalso([mensagem()], { credenciais: { api_key: 'k' } });
  const { criar, enviados } = adapterFalso('whatsapp', { ok: true });

  await despachar(banco, { criar: criar as never });

  assert.deepEqual(enviados[0], {
    messageId: 'm-1', destino: '+5511900000001', conteudo: 'Oi',
    remetente: 'instancia-a', credenciais: { api_key: 'k' },
  });
});

test('a culpa devolvida pelo adapter chega ao banco', async () => {
  // É o que impede um número inválido de derrubar uma conta boa.
  const { banco, registros } = bancoFalso([mensagem()]);
  const { criar } = adapterFalso('whatsapp',
    { ok: false, erro: 'not a WhatsApp user', culpa: 'destino' });

  const r = await despachar(banco, { criar: criar as never });

  assert.equal(r.falhas, 1);
  assert.equal(r.porCulpa.destino, 1);
  assert.equal(r.porCulpa.remetente, 0);
  assert.equal(registros[0].culpa, 'destino');
});

test('falha sem culpa declarada é tratada como transitória', async () => {
  const { banco, registros } = bancoFalso([mensagem()]);
  const { criar } = adapterFalso('whatsapp', { ok: false, erro: 'vago' });
  const r = await despachar(banco, { criar: criar as never });
  assert.equal(r.porCulpa.transitorio, 1);
  assert.equal(registros[0].culpa, 'transitorio');
});

test('uma mensagem que explode não derruba o lote', async () => {
  let n = 0;
  const { banco, registros } = bancoFalso([
    mensagem({ message_id: 'm-1' }),
    mensagem({ message_id: 'm-2' }),
    mensagem({ message_id: 'm-3' }),
  ]);
  const { criar } = adapterFalso('whatsapp', () => {
    n += 1;
    if (n === 2) throw new Error('provedor explodiu');
    return { ok: true, providerMessageId: `P${n}` };
  });

  const r = await despachar(banco, { criar: criar as never });

  assert.equal(r.reivindicadas, 3);
  assert.equal(r.enviadas, 2);
  assert.equal(r.falhas, 1);
  assert.equal(registros.length, 3, 'as três precisam ter resultado registrado');
  assert.equal(registros[1].ok, false);
  assert.equal(registros[1].erro, 'provedor explodiu');
});

test('credencial que não resolve culpa o remetente e não fica em silêncio', async () => {
  const { banco, registros } = bancoFalso([mensagem()], { erroCredencial: 'segredo ausente' });
  const { criar } = adapterFalso('whatsapp', { ok: true });

  const r = await despachar(banco, { criar: criar as never });

  assert.equal(r.falhas, 1);
  assert.equal(registros[0].culpa, 'remetente');
  assert.match(registros[0].erro!, /segredo ausente/);
});

test('provedor sem adapter vira falha registrada, não exceção solta', async () => {
  const { banco, registros } = bancoFalso([mensagem()], { provedor: 'uazapi' });
  const r = await despachar(banco); // registro real: uazapi não existe
  assert.equal(r.falhas, 1);
  assert.equal(registros[0].culpa, 'remetente');
  assert.match(registros[0].erro!, /provedor sem adapter/);
});

test('adapter de canal errado não envia', async () => {
  // Se o roteador escolheu remetente de outro canal, mandar mesmo assim
  // entregaria SMS por WhatsApp ou pior.
  const { banco, registros } = bancoFalso([mensagem({ canal: 'sms' })]);
  const { criar, enviados } = adapterFalso('whatsapp', { ok: true });

  const r = await despachar(banco, { criar: criar as never });

  assert.equal(enviados.length, 0);
  assert.equal(r.falhas, 1);
  assert.equal(registros[0].culpa, 'remetente');
  assert.match(registros[0].erro!, /whatsapp.*sms/);
});

test('não conseguir gravar o resultado sobe com contexto', async () => {
  // A mensagem fica no lease e volta ao pool quando ele vencer; engolir o erro
  // faria parecer que foi enviada.
  const { banco } = bancoFalso([mensagem()], { erroAoRegistrar: 'banco fora' });
  const { criar } = adapterFalso('whatsapp', { ok: true });

  await assert.rejects(
    () => despachar(banco, { criar: criar as never }),
    /falha ao registrar resultado da mensagem m-1: banco fora/,
  );
});

test('lote vazio não chama adapter nenhum', async () => {
  const { banco, registros } = bancoFalso([]);
  const { criar, enviados } = adapterFalso('whatsapp', { ok: true });
  const r = await despachar(banco, { criar: criar as never });
  assert.deepEqual(r.reivindicadas, 0);
  assert.equal(enviados.length, 0);
  assert.equal(registros.length, 0);
});

// ---------------------------------------------------------------------------
// Passada completa
// ---------------------------------------------------------------------------

test('uma passada roda o agendador antes de despachar', async () => {
  const { banco, chamadasAgendador } = bancoFalso([mensagem()]);
  const { criar } = adapterFalso('whatsapp', { ok: true });

  const r = await umaPassada(banco, 'real', { criar: criar as never });

  assert.equal(chamadasAgendador(), 1);
  assert.equal(r.agendadas, 7);
  assert.equal(r.despacho.enviadas, 1);
});

test('shadow mode não envia nada, porque não há pendente para reivindicar', async () => {
  // O agendador grava 'simulado'; reivindicar_pendentes só devolve 'pendente'.
  const { banco } = bancoFalso([]);
  const { criar, enviados } = adapterFalso('whatsapp', { ok: true });

  const r = await umaPassada(banco, 'simulado', { criar: criar as never });

  assert.equal(r.agendadas, 7);
  assert.equal(r.despacho.enviadas, 0);
  assert.equal(enviados.length, 0);
});

// ---------------------------------------------------------------------------
// Webhook
// ---------------------------------------------------------------------------

test('webhook normaliza e grava os eventos', async () => {
  const { banco, eventos } = bancoFalso([]);
  const { criar } = adapterFalso('whatsapp', { ok: true }, [
    { providerMessageId: 'P1', tipo: 'entregue', ocorridoEm: '2026-09-17T00:00:00Z', payload: {} },
    { providerMessageId: 'P2', tipo: 'respondido', ocorridoEm: '2026-09-17T00:00:01Z', payload: {} },
  ]);

  const r = await receberWebhook(banco, 'falso', {}, { criar: criar as never });

  assert.deepEqual(r, { normalizados: 2, gravados: 2, descartados: 0 });
  assert.deepEqual(eventos.map((e) => e.tipo), ['entregue', 'respondido']);
});

test('webhook conta o que o banco descartou', async () => {
  // Eco do próprio motor e id desconhecido voltam false do banco.
  const { banco } = bancoFalso([], { eventoAceito: (id) => id !== 'ECO' });
  const { criar } = adapterFalso('whatsapp', { ok: true }, [
    { providerMessageId: 'P1',  tipo: 'entregue', ocorridoEm: 'x', payload: {} },
    { providerMessageId: 'ECO', tipo: 'respondido', ocorridoEm: 'x', payload: {} },
  ]);

  const r = await receberWebhook(banco, 'falso', {}, { criar: criar as never });

  assert.deepEqual(r, { normalizados: 2, gravados: 1, descartados: 1 });
});

test('webhook sem evento reconhecível não grava nada', async () => {
  const { banco, eventos } = bancoFalso([]);
  const { criar } = adapterFalso('whatsapp', { ok: true }, []);
  const r = await receberWebhook(banco, 'falso', { lixo: true }, { criar: criar as never });
  assert.deepEqual(r, { normalizados: 0, gravados: 0, descartados: 0 });
  assert.equal(eventos.length, 0);
});

test('webhook de provedor desconhecido falha alto', async () => {
  const { banco } = bancoFalso([]);
  await assert.rejects(
    () => receberWebhook(banco, 'inexistente', {}),
    /provedor sem adapter/,
  );
});
