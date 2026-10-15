// E-mail via Resend (HTTP).
//
// O catálogo nasceu com `smtp` e `tem_adapter = false`, e ficou assim porque
// SMTP precisa de socket: `adapters/tipos.ts` diz, na primeira linha, que aqui
// não entra API de runtime — só `fetch`. É o que faz o mesmo arquivo rodar no
// Deno da edge function e no Node do teste. Abrir exceção para um canal
// derrubaria isso para todos (D30).
//
// Resend é API HTTP pura: uma chave Bearer, um POST, um id de volta. `smtp`
// continua no catálogo com `tem_adapter = false` — dizer em voz alta que não
// há adapter é melhor do que sumir com a opção.
//
// Três coisas do provedor que o motor ganha de graça:
//
// - `Idempotency-Key`. A invariante 1 já garante uma mensagem por
//   (enrollment, step) no banco; mandar o `message_id` como chave estende a
//   garantia para o outro lado da rede, onde o lease pode ter expirado e a
//   mesma mensagem ser reivindicada de novo.
// - `reply_to`. É por ele que a invariante 4 vale no e-mail: a resposta
//   precisa cair num domínio de inbound da Resend para virar `email.received`.
//   Sem isso a pessoa responde para uma caixa que o motor não lê, e a cadência
//   continua andando.
// - `email.bounced`. Quem diz que um endereço morreu é o bounce, não o retorno
//   do POST — ver o comentário em `culpaDoStatus`.

import type {
  Buscador, ChannelAdapter, EventoNormalizado, PedidoEnvio,
  ResultadoEnvio, Saude, TipoEvento,
} from './tipos.ts';
import { erroDeRede, exigir } from './tipos.ts';
import { emailValido, montarRemetente, normalizarEmail, separarAssunto } from './email.ts';
import { emCaminho, primeiroTexto } from './texto.ts';

const ENDPOINT = 'https://api.resend.com/emails';
const DOMINIOS = 'https://api.resend.com/domains';

export class EmailResendAdapter implements ChannelAdapter {
  readonly canal = 'email' as const;
  readonly provedor = 'resend';

  private readonly buscar: Buscador;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async send(pedido: PedidoEnvio): Promise<ResultadoEnvio> {
    let apiKey: string;
    let de: string;
    let assunto: string;
    let corpo: string;

    try {
      apiKey = exigir(pedido.credenciais, 'api_key');
      // `assunto_padrao` é obrigatório no catálogo justamente para que a falta
      // de assunto seja impossível em tempo de envio: ou o passo traz o seu,
      // ou vale este. Faltar aqui é conta mal configurada — culpa 'remetente',
      // que tira a conta do pool, e não 'destino', que invalidaria o e-mail do
      // contato por um erro que não é dele.
      const separado = separarAssunto(
        pedido.conteudo, exigir(pedido.credenciais, 'assunto_padrao'),
      );
      assunto = separado.assunto;
      corpo = separado.corpo;

      de = montarRemetente(pedido.remetente, pedido.credenciais.nome_remetente);
      if (!de) throw new Error('remetente sem endereço de e-mail');
    } catch (e) {
      return { ok: false, erro: (e as Error).message, culpa: 'remetente' };
    }

    const para = normalizarEmail(pedido.destino);
    if (!emailValido(para)) return { ok: false, erro: 'e-mail inválido', culpa: 'destino' };

    const responder = normalizarEmail(pedido.credenciais.responder_para ?? '');

    try {
      const resp = await this.buscar(ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${apiKey}`,
          'Idempotency-Key': pedido.messageId,
        },
        body: JSON.stringify({
          from: de,
          to: [para],
          subject: assunto,
          // Texto puro, não HTML: o template do passo é texto, e interpolar
          // campo de contato dentro de HTML é como se injeta marcação sem
          // querer. Toque frio em texto ainda entrega melhor.
          text: corpo,
          ...(responder ? { reply_to: responder } : {}),
        }),
      });

      const body = await resp.json().catch(() => ({} as Record<string, unknown>));
      const c = body as { id?: string; name?: string; message?: string };

      if (!resp.ok || !c.id) {
        return {
          ok: false,
          erro: c.message ?? c.name ?? `HTTP ${resp.status}`,
          culpa: culpaDoStatus(resp.status),
        };
      }

      return { ok: true, providerMessageId: c.id };
    } catch (e) {
      return erroDeRede(e);
    }
  }

  /**
   * Webhook da Resend: um evento por POST, `{type, created_at, data}`.
   *
   * Dois casamentos diferentes, como manda `tipos.ts`:
   *
   * - Evento de mensagem que nós mandamos — `data.email_id` é o id que veio no
   *   POST de envio, então casa por `providerMessageId`.
   * - `email.received` — é e-mail de entrada. O `data.email_id` aí é da
   *   mensagem *dela*, que não existe em `messages`; usá-lo gravaria um evento
   *   que nunca casa. O vínculo é pelo endereço de quem escreveu, resolvido no
   *   banco a partir do chip que recebeu o webhook (D23).
   */
  normalizeWebhook(corpo: unknown): EventoNormalizado[] {
    const raiz = corpo as {
      type?: string;
      created_at?: string;
      data?: { email_id?: string; from?: string; created_at?: string };
    };

    const tipoBruto = String(raiz?.type ?? '');
    const dados = raiz?.data ?? {};
    const quando = instante(raiz?.created_at ?? dados.created_at);

    if (tipoBruto === 'email.received') {
      const de = normalizarEmail(String(dados.from ?? ''));
      if (!emailValido(de)) return [];
      return [{
        deNumero: de,
        tipo: 'respondido',
        ocorridoEm: quando,
        payload: {
          evento: tipoBruto,
          de,
          autoria: null,
          // O corpo, quando o provedor manda. Sem `html` de propósito: tag
          // virando texto encheria o classificador de opt-out de ruído (D48).
          texto: primeiroTexto((dados as Record<string, unknown>).text,
                                (dados as Record<string, unknown>).subject) ?? null,
        },
      }];
    }

    const tipo = TIPO_POR_EVENTO[tipoBruto];
    if (!tipo || !dados.email_id) return [];

    return [{
      providerMessageId: String(dados.email_id),
      tipo,
      ocorridoEm: quando,
      payload: {
        evento: tipoBruto,
        // Só a devolução carrega isto, e só quando o provedor distingue. A
        // ausência é lida como temporária pelo SQL, de propósito: suprimir um
        // endereço bom por uma caixa cheia é irreversível (D49).
        ...(tipo === 'devolvido' ? { permanente: devolucaoPermanente(raiz) } : {}),
      },
    }];
  }

  async checkHealth(credenciais: Record<string, string>): Promise<Saude> {
    try {
      const resp = await this.buscar(DOMINIOS, {
        headers: { Authorization: `Bearer ${exigir(credenciais, 'api_key')}` },
      });
      return { ok: resp.ok, detalhe: `HTTP ${resp.status}` };
    } catch (e) {
      return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
    }
  }
}

/**
 * `email.delivery_delayed`, `email.scheduled` e `email.suppressed` ficam de
 * fora: não há tipo de evento para eles e inventar um vizinho ('falha' para um
 * atraso que ainda vai entregar) estraga o status derivado.
 *
 * `email.complained` é o contato marcando como spam, e desde o D49 ele tem
 * evento próprio: `denuncia`, que suprime a PESSOA e faz o CRM ouvir
 * `opt_out`. Antes caía em 'rejeitado' junto com o bounce, o que apagava a
 * diferença entre "a pessoa não quer" e "o endereço não existe".
 */
/**
 * A devolução foi definitiva?
 *
 * `true` só quando o provedor DIZ que foi. Qualquer outra coisa — campo
 * ausente, nome de campo que mudou, valor inesperado — é lida como temporária,
 * porque suprimir um endereço bom não tem volta e deixar um endereço morto no
 * pool custa uma tentativa perdida por vez.
 */
function devolucaoPermanente(raiz: unknown): boolean {
  const bruto = primeiroTexto(
    emCaminho(raiz, 'data', 'bounce', 'type'),
    emCaminho(raiz, 'data', 'bounce_type'),
    emCaminho(raiz, 'data', 'type'),
  );
  if (!bruto) return false;
  const v = bruto.toLowerCase();
  return v === 'permanent' || v === 'hard' || v === 'hardbounce';
}

const TIPO_POR_EVENTO: Record<string, TipoEvento> = {
  'email.sent': 'enviado',
  'email.delivered': 'entregue',
  'email.opened': 'lido',
  'email.clicked': 'clique',
  // Os dois eram `rejeitado`, o que apagava a diferença entre "o endereço não
  // existe" e "a pessoa marcou como spam" — e essa diferença decide se o CRM
  // ouve `identidade_invalida` ou `opt_out` (D49).
  'email.bounced': 'devolvido',
  'email.complained': 'denuncia',
  'email.failed': 'falha',
};

/**
 * 4xx da Resend quase nunca é o contato: é domínio não verificado, chave sem
 * permissão de envio ou `from` fora do domínio. Marcar isso como 'destino'
 * invalidaria `contact_identities` e escreveria `identidade_invalida` no CRM
 * por um erro que é da conta — estrago que o backfill não desfaz.
 *
 * Endereço que não existe aparece como `email.bounced` no webhook, e é de lá
 * que essa conclusão tem que vir. Aqui, na dúvida, a conta sai do pool.
 */
function culpaDoStatus(status: number): 'remetente' | 'destino' | 'transitorio' {
  if (status === 429 || status >= 500) return 'transitorio';
  return 'remetente';
}

function instante(bruto: unknown): string {
  if (typeof bruto === 'string' && bruto) {
    const d = new Date(bruto);
    if (!Number.isNaN(d.getTime())) return d.toISOString();
  }
  return new Date().toISOString();
}
