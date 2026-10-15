// Despachante: pega o que o agendador reivindicou e manda pelo adapter.
//
// Não decide nada de cadência nem de roteamento — isso já aconteceu em
// `processar_vencidos`. Aqui é só: resolver credencial, escolher adapter,
// enviar, registrar o que aconteceu.
//
// Uma mensagem que explode não pode derrubar o lote inteiro: cada uma é
// tratada isoladamente, e a falha vira resultado registrado, não exceção que
// sobe e deixa as outras presas no lease até vencer.

import type { Banco, Culpa, MensagemParaEnviar } from './porta.ts';
import type { Buscador, ResultadoEnvio } from '../adapters/tipos.ts';
import { criarAdapter } from '../adapters/registro.ts';

export interface ResumoDespacho {
  readonly reivindicadas: number;
  readonly enviadas: number;
  readonly falhas: number;
  readonly porCulpa: Record<Culpa, number>;
}

export interface OpcoesDespacho {
  readonly limite?: number;
  readonly buscar?: Buscador;
  /** Injetável para teste; por padrão o registro real. */
  readonly criar?: typeof criarAdapter;
}

export async function despachar(
  banco: Banco,
  opcoes: OpcoesDespacho = {},
): Promise<ResumoDespacho> {
  const limite = opcoes.limite ?? 50;
  const criar = opcoes.criar ?? criarAdapter;

  const pendentes = await banco.reivindicarPendentes(limite);

  const resumo = {
    reivindicadas: pendentes.length,
    enviadas: 0,
    falhas: 0,
    porCulpa: { remetente: 0, destino: 0, transitorio: 0 } as Record<Culpa, number>,
  };

  for (const m of pendentes) {
    const r = await enviarUma(banco, m, criar, opcoes.buscar);
    if (r.ok) {
      resumo.enviadas += 1;
    } else {
      resumo.falhas += 1;
      resumo.porCulpa[r.culpa ?? 'transitorio'] += 1;
    }
  }

  return resumo;
}

async function enviarUma(
  banco: Banco,
  m: MensagemParaEnviar,
  criar: typeof criarAdapter,
  buscar?: Buscador,
): Promise<ResultadoEnvio> {
  let resultado: ResultadoEnvio;

  try {
    const { provedor, credenciais } = await banco.credenciaisDoRemetente(m.sender_id);
    const adapter = criar(provedor, buscar);

    if (adapter.canal !== m.canal) {
      // O roteador escolheu um remetente de outro canal, ou o registro está
      // errado. Não enviar é o certo; culpar o remetente tira a conta do pool
      // até alguém olhar.
      resultado = {
        ok: false,
        erro: `adapter de ${adapter.canal} para mensagem de ${m.canal}`,
        culpa: 'remetente',
      };
    } else {
      resultado = await adapter.send({
        messageId: m.message_id,
        destino: m.destino,
        conteudo: m.conteudo,
        remetente: m.sender_ident,
        credenciais,
      });
    }
  } catch (e) {
    // Credencial que não resolve, provedor sem adapter: é a conta que está
    // mal configurada, não a mensagem.
    resultado = {
      ok: false,
      erro: e instanceof Error ? e.message : String(e),
      culpa: 'remetente',
    };
  }

  try {
    await banco.registrarResultado(
      m.message_id,
      resultado.ok,
      resultado.providerMessageId,
      resultado.erro,
      resultado.culpa ?? 'transitorio',
    );
  } catch (e) {
    // Não conseguir gravar o resultado é pior do que não ter enviado: a
    // mensagem fica no lease e volta ao pool quando ele vencer. Deixa o erro
    // subir com contexto, para o worker registrar e a próxima passada tentar.
    throw new Error(
      `falha ao registrar resultado da mensagem ${m.message_id}: ` +
      (e instanceof Error ? e.message : String(e)),
    );
  }

  return resultado;
}

/** Uma passada completa: agendador e depois despacho. */
export async function umaPassada(
  banco: Banco,
  modo: 'simulado' | 'real',
  opcoes: OpcoesDespacho = {},
): Promise<{ agendadas: number; despacho: ResumoDespacho }> {
  const agendadas = await banco.processarVencidos(opcoes.limite ?? 100, modo);

  // Em shadow mode não há nada a despachar: as mensagens nascem 'simulado' e
  // `reivindicar_pendentes` só devolve 'pendente'. Chamar o despacho mesmo
  // assim custa uma consulta e documenta que o caminho é o mesmo.
  const despacho = await despachar(banco, opcoes);

  return { agendadas, despacho };
}
