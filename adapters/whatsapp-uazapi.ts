// WhatsApp não oficial via UAZAPI.
//
// D14 tinha deixado uma pergunta em aberto: se havia compromisso com UAZAPI
// que o inventário não enxergava. A resposta veio — há. Então UAZAPI é o
// não-oficial daqui para frente, e a Evolution continua no catálogo porque é
// o que roda hoje no legado e o que os chips existentes usam (D22).
//
// O que está confirmado na documentação e o que é defensivo, para quem mexer
// depois não confundir uma coisa com a outra:
//
//   confirmado  POST {base}/send/text, corpo {number, text}
//   confirmado  autenticação por header `token` (o da instância).
//               `adminToken` é só para endpoints administrativos e não é usado
//               aqui — o adapter nunca precisa de poder de admin para enviar.
//   confirmado  webhook com evento `messages`, e o filtro `wasSentByApi`, que
//               é o eco do que nós mesmos mandamos
//   defensivo   o nome do campo que carrega o id da mensagem na resposta e no
//               webhook varia entre versões; por isso é lido de uma lista de
//               candidatos em vez de um caminho fixo
//
// Ser tolerante no id não é desleixo: sem id do provedor não há como ligar o
// retorno à mensagem que o motor mandou, e é melhor aceitar três grafias do
// que gravar uma mensagem que nunca vai casar com o webhook.

import type {
  Buscador, ChannelAdapter, EventoNormalizado, PedidoEnvio, PedidoProvisionamento,
  ResultadoEnvio, ResultadoProvisionamento, Saude, TipoEvento,
} from './tipos.ts';
import { erroDeRede, exigir } from './tipos.ts';
import { normalizarTelefone } from './telefone.ts';
import { emCaminho, primeiroTexto } from './texto.ts';

export class WhatsAppUazapiAdapter implements ChannelAdapter {
  readonly canal = 'whatsapp' as const;
  readonly provedor = 'uazapi';

  private readonly buscar: Buscador;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async send(pedido: PedidoEnvio): Promise<ResultadoEnvio> {
    let base: string;
    let token: string;
    try {
      base = exigir(pedido.credenciais, 'base_url').replace(/\/$/, '');
      token = exigir(pedido.credenciais, 'token');
    } catch (e) {
      return { ok: false, erro: (e as Error).message, culpa: 'remetente' };
    }

    const numero = normalizarTelefone(pedido.destino);
    if (!numero) return { ok: false, erro: 'destino sem dígitos', culpa: 'destino' };

    try {
      const resp = await this.buscar(`${base}/send/text`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', token },
        body: JSON.stringify({ number: numero, text: pedido.conteudo }),
      });

      const corpo = await resp.json().catch(() => ({} as Record<string, unknown>));

      if (!resp.ok) {
        const msg = mensagemDeErro(corpo);
        return { ok: false, erro: msg ?? `HTTP ${resp.status}`, culpa: culpaUazapi(resp.status, msg) };
      }

      const id = idDaMensagem(corpo);
      if (!id) {
        return { ok: false, erro: 'resposta sem id de mensagem', culpa: 'transitorio' };
      }
      return { ok: true, providerMessageId: id };
    } catch (e) {
      return erroDeRede(e);
    }
  }

  normalizeWebhook(corpo: unknown): EventoNormalizado[] {
    const raiz = corpo as Record<string, unknown>;
    if (!raiz) return [];

    const evento = String(raiz.event ?? raiz.EventType ?? raiz.type ?? '');
    const bruto = (raiz.message ?? raiz.data ?? raiz.payload ?? null) as
      | Record<string, unknown>
      | Record<string, unknown>[]
      | null;
    if (!bruto) return [];

    const itens = Array.isArray(bruto) ? bruto : [bruto];

    return itens.flatMap((item): EventoNormalizado[] => {
      // Eco: o que a própria instância mandou. Tratar como resposta do contato
      // encerraria o enrollment no próprio disparo.
      if (item.fromMe === true || item.wasSentByApi === true) return [];

      // Mudança de status do que nós mandamos — aqui o id é o da nossa
      // mensagem, então casa direto.
      const status = TIPO_POR_STATUS[String(item.status ?? item.ack ?? '').toLowerCase()];
      if (evento.includes('status') || (status && !ehMensagemRecebida(evento, item))) {
        const id = idDaMensagem(item);
        if (!id || !status) return [];
        return [{
          providerMessageId: id,
          tipo: status,
          ocorridoEm: instante(item.messageTimestamp ?? item.timestamp ?? item.t),
          payload: { status: item.status ?? item.ack ?? null },
        }];
      }

      // Mensagem recebida. Duas formas de ligar ao enrollment:
      //
      // com citação — o provedor disse a qual mensagem nossa ele respondeu;
      //               casa por id, igual às oficiais.
      // sem citação — o caso comum aqui. O id do payload é o da mensagem DELE
      //               e não existe em `messages`; quem casa é o número, no
      //               banco, a partir do chip que recebeu este webhook (D23).
      const de = numeroDe(item);
      const base = {
        tipo: 'respondido' as TipoEvento,
        ocorridoEm: instante(item.messageTimestamp ?? item.timestamp ?? item.t),
        payload: {
          de: item.sender ?? item.from ?? item.chatid ?? null,
          tipo_mensagem: item.messageType ?? item.type ?? null,
          // A UAZAPI varia o nome conforme a versão e o tipo. Todos os
          // caminhos conhecidos, em ordem; nenhum é garantido (D48).
          texto: primeiroTexto(
            item.text, item.content, item.body, item.caption,
            emCaminho(item, 'message', 'conversation'),
            emCaminho(item, 'message', 'extendedTextMessage', 'text'),
            emCaminho(item, 'message', 'imageMessage', 'caption'),
          ) ?? null,
        },
      };

      const citado = idCitado(item);
      if (citado) return [{ providerMessageId: citado, ...base }];
      if (de) return [{ deNumero: de, ...base }];
      return [];
    });
  }

  provisionar(pedido: PedidoProvisionamento): Promise<ResultadoProvisionamento> {
    return provisionarUazapi(this.buscar, pedido);
  }

  async checkHealth(credenciais: Record<string, string>): Promise<Saude> {
    try {
      const base = exigir(credenciais, 'base_url').replace(/\/$/, '');
      const resp = await this.buscar(`${base}/instance/status`, {
        headers: { token: exigir(credenciais, 'token') },
      });
      return { ok: resp.ok, detalhe: `HTTP ${resp.status}` };
    } catch (e) {
      return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
    }
  }
}

/**
 * Cria instância no servidor da UAZAPI.
 *
 *   confirmado  POST {base}/instance/init cria, header `admintoken`
 *   confirmado  POST {base}/instance/connect conecta e devolve o QR
 *   defensivo   o token da instância vem em `token` na resposta do init; lido
 *               de uma lista de grafias pelo mesmo motivo do id de mensagem
 *
 * O QR não é guardado em lugar nenhum: é devolvido para a tela e morre ali.
 * Guardar QR seria guardar uma credencial de sessão de WhatsApp.
 */
async function provisionarUazapi(
  buscar: Buscador, pedido: PedidoProvisionamento,
): Promise<ResultadoProvisionamento> {
  const base = pedido.baseUrl.replace(/\/$/, '');
  const cabecalho = { 'Content-Type': 'application/json', admintoken: pedido.adminToken };

  try {
    const criada = await buscar(`${base}/instance/init`, {
      method: 'POST',
      headers: cabecalho,
      body: JSON.stringify({
        name: pedido.nome,
        // A UAZAPI aponta o webhook por instância, que é exatamente o que o
        // motor precisa: um endpoint por chip.
        ...(pedido.webhookUrl ? { webhook: pedido.webhookUrl } : {}),
      }),
    });

    const corpo = await criada.json().catch(() => ({} as Record<string, unknown>));
    if (!criada.ok) {
      return { ok: false, erro: mensagemDeErro(corpo) ?? `HTTP ${criada.status}` };
    }

    const token = tokenDaInstancia(corpo);
    if (!token) return { ok: false, erro: 'instância criada sem token — não dá para usar' };

    const instancia = String(
      (corpo.name ?? corpo.instance ?? (corpo.instance as Record<string, unknown>)?.name)
      ?? pedido.nome,
    );

    // Conectar é o que gera o QR. Falhar aqui não desfaz a instância: ela
    // existe e pode ser conectada depois pela tela.
    let qrcode: string | undefined;
    try {
      const conectada = await buscar(`${base}/instance/connect`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', token },
        body: JSON.stringify({}),
      });
      const c = await conectada.json().catch(() => ({} as Record<string, unknown>));
      qrcode = qrDe(c);
    } catch { /* instância existe; o QR se pede de novo */ }

    return {
      ok: true,
      instancia,
      qrcode,
      credenciais: { token, base_url: base },
    };
  } catch (e) {
    return { ok: false, erro: e instanceof Error ? e.message : String(e) };
  }
}

function tokenDaInstancia(o: Record<string, unknown>): string | null {
  const ninho = (o.instance ?? o.data) as Record<string, unknown> | undefined;
  for (const fonte of [o, ninho]) {
    const v = fonte?.token ?? fonte?.apikey ?? fonte?.instanceToken;
    if (typeof v === 'string' && v) return v;
  }
  return null;
}

function qrDe(o: Record<string, unknown>): string | undefined {
  const ninho = (o.instance ?? o.data) as Record<string, unknown> | undefined;
  for (const fonte of [o, ninho]) {
    const v = fonte?.qrcode ?? fonte?.qrCode ?? fonte?.qr;
    if (typeof v === 'string' && v) return v;
  }
  return undefined;
}

/** O número de quem mandou, normalizado — é por ele que a resposta casa. */
function numeroDe(item: Record<string, unknown>): string | null {
  const bruto = item.sender ?? item.from ?? item.chatid ?? item.chatId;
  if (typeof bruto !== 'string' || !bruto) return null;
  // Vem como JID: 5511900000001@s.whatsapp.net. Grupo não é conversa de
  // cadência — o motor nunca mandou para um, então não pode ser resposta.
  if (bruto.includes('@g.us')) return null;
  return normalizarTelefone(bruto.split('@')[0] ?? bruto) || null;
}

const TIPO_POR_STATUS: Record<string, TipoEvento> = {
  sent: 'enviado',
  server_ack: 'enviado',
  delivered: 'entregue',
  delivery_ack: 'entregue',
  read: 'lido',
  played: 'lido',
  failed: 'falha',
  error: 'falha',
};

function ehMensagemRecebida(evento: string, item: Record<string, unknown>): boolean {
  return evento.includes('message') && item.fromMe !== true
    && (idCitado(item) !== null || numeroDe(item) !== null);
}

/** O id da nossa mensagem, nas grafias que a UAZAPI já usou. */
function idDaMensagem(o: Record<string, unknown> | null | undefined): string | null {
  if (!o) return null;
  const direto = o.id ?? o.messageid ?? o.messageId ?? o.uazapi_message_id;
  if (typeof direto === 'string' && direto) return direto;

  const chave = (o.key ?? (o.message as Record<string, unknown> | undefined)?.key) as
    | { id?: string } | undefined;
  if (typeof chave?.id === 'string' && chave.id) return chave.id;

  const aninhado = (o.message ?? o.data) as Record<string, unknown> | undefined;
  if (aninhado && aninhado !== o) {
    const v = aninhado.id ?? aninhado.messageid ?? aninhado.messageId;
    if (typeof v === 'string' && v) return v;
  }
  return null;
}

/** O id da mensagem citada — o vínculo com o que o motor mandou. */
function idCitado(o: Record<string, unknown>): string | null {
  const ctx = (o.quoted ?? o.quotedMsg ?? o.context ?? o.contextInfo) as
    | Record<string, unknown> | undefined;
  if (ctx) {
    const v = idDaMensagem(ctx) ?? (ctx.stanzaId as string | undefined);
    if (typeof v === 'string' && v) return v;
  }
  const direto = o.quotedMessageId ?? o.stanzaId;
  return typeof direto === 'string' && direto ? direto : null;
}

function mensagemDeErro(corpo: Record<string, unknown>): string | undefined {
  const v = corpo.error ?? corpo.message ?? corpo.erro;
  return typeof v === 'string' ? v : undefined;
}

// Token inválido e instância desconectada derrubam a conta; número fora do
// WhatsApp é culpa do destino e não pode esvaziar o pool.
function culpaUazapi(status: number, mensagem?: string): ResultadoEnvio['culpa'] {
  const m = (mensagem ?? '').toLowerCase();
  if (status === 401 || status === 403) return 'remetente';
  if (m.includes('token') || m.includes('unauthor')) return 'remetente';
  if (m.includes('disconnect') || m.includes('not connected') || m.includes('desconect')) {
    return 'remetente';
  }
  if (m.includes('not exist') || m.includes('não existe') || m.includes('invalid number')) {
    return 'destino';
  }
  if (status === 404 || status === 400) return 'destino';
  if (status === 429) return 'transitorio';
  return 'transitorio';
}

function instante(bruto: unknown): string {
  const n = Number(bruto);
  if (Number.isFinite(n) && n > 0) {
    return new Date(n < 1e12 ? n * 1000 : n).toISOString();
  }
  return new Date().toISOString();
}
