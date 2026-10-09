// E-mail via SMTP Locaweb — pela API HTTP do produto, não pelo protocolo SMTP.
//
// O nome engana: o "SMTP Locaweb" é um serviço de envio que também tem API
// REST (`api.smtplw.com.br`, token no cabeçalho `x-auth-token`). É ela que
// cabe aqui. O protocolo SMTP continua fora pelo motivo de sempre: precisa de
// socket, e este diretório só fala `fetch` (D30). O `smtp` genérico segue no
// catálogo sem adapter.
//
// Três diferenças para o Resend, e cada uma custou uma escolha (D61):
//
// - O assunto vai como está. A API pede ASCII ou "encoded-word" (RFC 2047), e
//   quase todo assunto em português tem acento — por isso `codificarAssunto`.
//
// - O webhook não traz o id que o POST devolveu. Traz de volta o valor do
//   cabeçalho `X-Smtplw` da mensagem, e mais nada que a identifique. Então o
//   `message_id` do motor vai nesse cabeçalho e é ELE o `providerMessageId`:
//   o evento casa pelo que nós mandamos, dentro do tenant do chip (D38). O id
//   numérico da Locaweb não é guardado, porque nada o lê de volta.
//
// - Não existe e-mail de entrada. A resposta vai para o `Reply-To`, e se ele
//   não apontar para um inbound que o motor lê, a pessoa responde para uma
//   caixa que ninguém processa e a cadência continua andando — a invariante 4
//   furada em silêncio. Por isso `responder_para` é OBRIGATÓRIO aqui, e não é
//   no Resend: lá o próprio domínio de envio pode receber.
//
// E uma que não tem conserto deste lado: a API não aceita chave de
// idempotência. A invariante 1 continua garantida no banco; o que se perde é
// a proteção extra do Resend para quando o lease expira com o POST em voo.

import type {
  Buscador, ChannelAdapter, EventoNormalizado, PedidoEnvio,
  ResultadoEnvio, Saude,
} from './tipos.ts';
import { erroDeRede, exigir } from './tipos.ts';
import { codificarAssunto, emailValido, normalizarEmail, separarAssunto } from './email.ts';
import { primeiroTexto } from './texto.ts';

const BASE = 'https://api.smtplw.com.br/v1';

/** O cabeçalho que o webhook devolve. É por ele que o evento acha a mensagem. */
export const CABECALHO_CORRELACAO = 'X-Smtplw';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class EmailLocawebAdapter implements ChannelAdapter {
  readonly canal = 'email' as const;
  readonly provedor = 'locaweb';

  private readonly buscar: Buscador;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async send(pedido: PedidoEnvio): Promise<ResultadoEnvio> {
    let token: string;
    let de: string;
    let responder: string;
    let assunto: string;
    let corpo: string;

    // Tudo o que é configuração da conta falha como 'remetente': tira a conta
    // do pool, e não invalida o e-mail de um contato por um erro que não é
    // dele (D30).
    try {
      token = exigir(pedido.credenciais, 'api_token');

      const separado = separarAssunto(
        pedido.conteudo, exigir(pedido.credenciais, 'assunto_padrao'),
      );
      assunto = codificarAssunto(separado.assunto);
      corpo = separado.corpo;

      // Só o endereço: a API declara `from` como e-mail, e um remetente
      // confirmado no painel. Nome de exibição fica por conta do painel.
      de = normalizarEmail(pedido.remetente);
      if (!emailValido(de)) throw new Error('remetente sem endereço de e-mail');

      responder = normalizarEmail(exigir(pedido.credenciais, 'responder_para'));
      if (!emailValido(responder)) throw new Error('responder_para não é um e-mail');
    } catch (e) {
      return { ok: false, erro: (e as Error).message, culpa: 'remetente' };
    }

    const para = normalizarEmail(pedido.destino);
    if (!emailValido(para)) return { ok: false, erro: 'e-mail inválido', culpa: 'destino' };

    try {
      const resp = await this.buscar(`${BASE}/messages`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'x-auth-token': token,
        },
        body: JSON.stringify({
          subject: assunto,
          // Texto puro, pelo mesmo motivo do Resend: o template é texto, e
          // campo de contato interpolado em HTML é marcação injetada.
          body: corpo,
          to: para,
          from: de,
          headers: {
            'Content-Type': 'text/plain; charset=UTF-8',
            'Reply-To': responder,
            [CABECALHO_CORRELACAO]: pedido.messageId,
          },
        }),
      });

      if (!resp.ok) {
        const body = await resp.json().catch(() => ({} as Record<string, unknown>));
        return {
          ok: false,
          erro: mensagemDeErro(body) ?? `HTTP ${resp.status}`,
          culpa: culpaDoStatus(resp.status),
        };
      }

      // 2xx é sucesso mesmo sem id no corpo, ao contrário do Resend: aqui o id
      // do provedor não serve para casar nada, e tratar um envio enfileirado
      // como falha é convidar o reenvio — sem chave de idempotência, isso é
      // e-mail duplicado na caixa do contato.
      return { ok: true, providerMessageId: pedido.messageId };
    } catch (e) {
      return erroDeRede(e);
    }
  }

  /**
   * Webhook do SMTP Locaweb: um POST `x-www-form-urlencoded` por evento, que
   * `canal-webhook` entrega já como objeto. Só existem dois:
   *
   * - bounce: `bounce_code`, `bounce_description`, `to`, `x-smtplw`;
   * - abertura: `opened_at`, `to`, `x-smtplw`.
   *
   * Entrega, clique, denúncia e resposta não chegam — não há de onde tirá-los,
   * e inventar um vizinho estragaria o status derivado.
   *
   * Evento sem o nosso `X-Smtplw` é descartado: é e-mail que outro sistema
   * mandou pela mesma conta Locaweb, e não é assunto do motor.
   */
  normalizeWebhook(corpo: unknown): EventoNormalizado[] {
    const campos = comoCampos(corpo);
    const correlacao = (campos['x-smtplw'] ?? '').trim();
    if (!UUID.test(correlacao)) return [];

    const codigo = primeiroTexto(campos.bounce_code);
    const descricao = primeiroTexto(campos.bounce_description);

    if (codigo || descricao) {
      return [{
        providerMessageId: correlacao,
        tipo: 'devolvido',
        ocorridoEm: new Date().toISOString(),
        payload: {
          evento: 'bounce',
          codigo: codigo ?? null,
          descricao: descricao ?? null,
          permanente: enderecoMorto(codigo),
        },
      }];
    }

    const aberto = primeiroTexto(campos.opened_at);
    if (aberto) {
      return [{
        providerMessageId: correlacao,
        tipo: 'lido',
        ocorridoEm: instante(aberto),
        payload: { evento: 'abertura' },
      }];
    }

    return [];
  }

  async checkHealth(credenciais: Record<string, string>): Promise<Saude> {
    try {
      const resp = await this.buscar(`${BASE}/settings/domains`, {
        headers: {
          Accept: 'application/json',
          'x-auth-token': exigir(credenciais, 'api_token'),
        },
      });
      return { ok: resp.ok, detalhe: `HTTP ${resp.status}` };
    } catch (e) {
      return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
    }
  }
}

/**
 * A devolução diz que o ENDEREÇO não existe?
 *
 * A Locaweb manda o código de status estendido do SMTP (RFC 3463), não uma
 * etiqueta "hard"/"soft". Só `5.1.x` — status de endereço, permanente — conta:
 * `5.1.1` caixa inexistente, `5.1.2` domínio inexistente. Um `5.7.x` também é
 * permanente, mas é política do servidor de destino (reputação, conteúdo), e
 * suprimir o endereço por isso seria culpar o contato pela conta. Caixa cheia
 * e o desconhecido ficam temporários: suprimir não tem volta (D49).
 */
function enderecoMorto(codigo: string | undefined): boolean {
  return /^5\.1\.\d+$/.test((codigo ?? '').trim());
}

/** Corpo do webhook como pares chave/valor, venha ele como vier. */
function comoCampos(corpo: unknown): Record<string, string> {
  if (typeof corpo === 'string') return Object.fromEntries(new URLSearchParams(corpo));
  if (corpo instanceof URLSearchParams) return Object.fromEntries(corpo);
  if (corpo && typeof corpo === 'object') {
    const saida: Record<string, string> = {};
    for (const [k, v] of Object.entries(corpo as Record<string, unknown>)) {
      if (typeof v === 'string') saida[k] = v;
    }
    return saida;
  }
  return {};
}

function mensagemDeErro(body: unknown): string | undefined {
  const erros = (body as { errors?: unknown })?.errors;
  if (Array.isArray(erros)) {
    const detalhes = erros
      .map((e) => primeiroTexto((e as Record<string, unknown>)?.detail,
                                (e as Record<string, unknown>)?.title))
      .filter((d): d is string => !!d);
    if (detalhes.length) return detalhes.join('; ');
  }
  return primeiroTexto((body as Record<string, unknown>)?.message,
                       (body as Record<string, unknown>)?.error);
}

/**
 * 401 é token, 403 é remetente não confirmado, 400/413/415 é pedido mal
 * montado — tudo da conta, nada do contato. Endereço que não existe aparece
 * depois, no bounce, e é de lá que essa conclusão tem que vir.
 */
function culpaDoStatus(status: number): 'remetente' | 'transitorio' {
  if (status === 429 || status >= 500) return 'transitorio';
  return 'remetente';
}

function instante(bruto: string): string {
  const d = new Date(bruto);
  return Number.isNaN(d.getTime()) ? new Date().toISOString() : d.toISOString();
}
