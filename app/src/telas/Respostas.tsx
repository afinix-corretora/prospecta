/** O que as pessoas responderam (D56).
 *
 * O texto da resposta é gravado desde o D48, quando os cinco adapters pararam
 * de jogá-lo fora. Um único leitor nasceu junto — o classificador de opt-out,
 * dentro do gatilho — e mais nenhum. A linha do tempo da campanha mostrava que
 * alguém respondeu e não mostrava o quê.
 *
 * O resultado, com tudo funcionando como projetado: a pessoa responde, a
 * cadência dela encerra em todas as campanhas (invariante 4), o opt-out é
 * detectado se for o caso — e uma pessoa interessada fica esperando uma
 * resposta que ninguém sabe que existe. Ler exigia abrir o painel do Supabase
 * e escrever SQL, que é o que o D26 diz que o produto não pode exigir.
 *
 * Esta tela é **leitura**. Não há "lida", não há "respondida", não há
 * atribuição: inventar estado aqui seria criar colunas sem quem as escreva, o
 * `tem_adapter` do D31 de novo. Quem responde de verdade é uma pessoa, no
 * aplicativo do canal, e é isso que a tela diz.
 *
 * Desde o D66 cada resposta pode trazer o rascunho do agente da campanha: o
 * texto pronto para copiar, ou o motivo de não haver texto.
 *
 * Desde o D69 o agente pode responder sozinho, e a tela diz o que aconteceu
 * com cada texto pela mensagem de verdade, não pelo desejo: "na fila",
 * "enviado", "simulado" — ou devolvido para uma pessoa, com o motivo e o texto
 * para copiar. A tela continua leitura: quem decide se sai é o motor.
 */
import { useEffect, useState } from 'react';
import { useSessao } from '../sessao';
import { Aviso, Kpi, NOME_CANAL, Secao, corCanal } from '../componentes/base';
import { lerRascunhos, lerRespostas } from '../dados';
import type { Rascunho, RespostaRecebida, SituacaoRascunho } from '../dados';
import { mensagemDeErro } from '../supabase';

export function Respostas() {
  const { tenant } = useSessao();
  const [lista, setLista] = useState<RespostaRecebida[]>([]);
  const [rascunhos, setRascunhos] = useState<Rascunho[]>([]);
  const [erro, setErro] = useState('');
  const [carregando, setCarregando] = useState(true);

  async function recarregar() {
    if (!tenant) return;
    setCarregando(true); setErro('');
    try {
      const [l, r] = await Promise.all([lerRespostas(tenant.tenant_id), lerRascunhos()]);
      setLista(l); setRascunhos(r);
    }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }

  useEffect(() => { void recarregar(); }, [tenant?.tenant_id]);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const opt = lista.filter((r) => r.suprimido).length;

  return (
    <div className="wrap">
      <div className="cabeca">
        <div>
        <h1>Respostas</h1>
        <p>O que voltou dos contatos, e o que o agente fez com cada resposta. Agente que
           responde sozinho manda pelo motor; o que ele não pôde mandar volta para você, com o
           motivo e o texto. Agente que não responde sozinho deixa o rascunho para você ler,
           ajustar e mandar pelo aplicativo do canal.</p>
        </div>
        <div className="cta"><button className="btn" onClick={() => void recarregar()}>Atualizar</button></div>
      </div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <section className="kpis">
        <Kpi rotulo="Respostas" valor={lista.length}
             sub={lista.length ? 'mais recente primeiro' : 'nenhuma ainda'} />
        <Kpi rotulo="Pediram para sair" valor={opt}
             sub={opt ? 'já suprimidos' : 'nenhum'} />
        <Kpi rotulo="Em aberto" valor={lista.length - opt}
             sub="gente que respondeu e não pediu para sair" />
      </section>

      <ListaDeRespostas lista={lista} rascunhos={rascunhos} />

    </div>
  );
}

/**
 * A lista, usada aqui e na tela da campanha.
 *
 * Cada resposta vem com a mensagem que a provocou. Sem isso, "sim, pode ser"
 * não quer dizer nada — e é justamente a resposta curta que é a mais comum.
 */
export function ListaDeRespostas({ lista, semCampanha, rascunhos = [] }: {
  lista: RespostaRecebida[]; semCampanha?: boolean; rascunhos?: Rascunho[];
}) {
  // Contato e instante, comparados como data: as duas pontas vêm do mesmo
  // `ocorrido_em`, mas por caminhos que podem formatar o texto diferente.
  const chave = (contato: string, quando: string) => `${contato}|${new Date(quando).getTime()}`;
  const doAgente = new Map(rascunhos.map((r) => [chave(r.contact_id, r.resposta_em), r]));

  if (lista.length === 0) {
    return (
      <div className="painel">
        <p className="vazio" style={{ margin: 0 }}>
          Nenhuma resposta ainda. Em shadow mode nada sai, então nada volta —
          respostas só aparecem depois que o motor passa a enviar de verdade.
        </p>
      </div>
    );
  }

  return (
    <>
      {!semCampanha && (
        <Secao titulo="O que chegou"
               nota={`${lista.length} ${lista.length === 1 ? 'resposta' : 'respostas'}`} />
      )}
      <div className="painel">
        {lista.map((r, i) => (
          <div key={`${r.contact_id}-${r.ocorrido_em}-${i}`}
               style={{
                 padding: '12px 0',
                 borderTop: i === 0 ? undefined : '1px solid var(--line)',
               }}>
            <div style={{ display: 'flex', gap: 9, alignItems: 'baseline', flexWrap: 'wrap' }}>
              <b style={{ color: 'var(--ink)' }}>{r.contato}</b>
              <span style={{ color: corCanal(r.canal), fontSize: 12 }}>
                {NOME_CANAL[r.canal] ?? r.canal}
              </span>
              <span className="mono" style={{ fontSize: 12, color: 'var(--ink-3)' }}>
                {r.destino}
              </span>
              <span style={{ fontSize: 12, color: 'var(--ink-3)' }}>{quando(r.ocorrido_em)}</span>
              {!semCampanha && (
                <span className="chip">{r.campanha}{r.passo ? ` · passo ${r.passo}` : ''}</span>
              )}
              {r.suprimido && (
                <span className="chip" style={{ background: 'var(--crit-soft)', color: 'var(--crit)' }}>
                  suprimido{r.motivo_supressao ? ` · ${r.motivo_supressao}` : ''}
                </span>
              )}
            </div>

            {/* A pergunta antes da resposta, e em cinza: é o que o motor
                mandou, não o que a pessoa disse. */}
            <p style={{
              margin: '8px 0 0', fontSize: 13, color: 'var(--ink-3)',
              borderLeft: '2px solid var(--line)', paddingLeft: 9, whiteSpace: 'pre-wrap',
            }}>
              {r.em_resposta_a}
            </p>

            {r.texto === null ? (
              // Vazio é honesto: o provedor não mandou o texto como string.
              // Escrever "[object Object]" seria inventar que ela disse isso.
              <p style={{ margin: '6px 0 0', fontSize: 13 }}>
                <i style={{ color: 'var(--ink-3)' }}>
                  A pessoa respondeu, e o provedor não mandou o texto em formato
                  legível — pode ter sido áudio, imagem ou anexo. Abra a conversa
                  no aplicativo do canal.
                </i>
              </p>
            ) : (
              <p style={{ margin: '6px 0 0', color: 'var(--ink)', whiteSpace: 'pre-wrap' }}>
                {r.texto}
              </p>
            )}

            <RascunhoDaResposta r={doAgente.get(chave(r.contact_id, r.ocorrido_em))} />

            {r.suprimido && (
              <p style={{ margin: '6px 0 0', fontSize: 12, color: 'var(--crit)' }}>
                Esta pessoa está na supressão — não fale com ela por este canal.
                A supressão é definitiva e não se desfaz pela tela.
              </p>
            )}
          </div>
        ))}
      </div>
    </>
  );
}

const POR_QUE_NAO: Record<Exclude<SituacaoRascunho, 'pronto'>, string> = {
  recusa: 'Sem rascunho: é recusa da oferta.',
  escalar: 'O agente passou para uma pessoa.',
  bloqueado: 'O texto do agente foi barrado por um freio.',
  limite: 'Sem rascunho: a conversa passou do limite de trocas do agente.',
  sem_credencial: 'Sem rascunho: o agente não tem com que compor.',
  erro: 'O provedor de IA recusou compor.',
};

/** O que aconteceu com a mensagem que o agente mandou (D69). Lido da mensagem,
 *  não do rascunho: "foi para a fila" não é "saiu". */
const ESTADO_DA_MENSAGEM: Record<string, string> = {
  pendente: 'na fila do motor — sai na próxima passada',
  enviado: 'enviada pelo agente',
  simulado: 'simulada — o motor está em shadow mode, nada saiu',
  falha: 'o provedor recusou o envio',
  cancelado: 'cancelada antes de sair',
};

/** O rascunho embaixo da resposta: o texto para copiar, ou o porquê de não haver. */
function RascunhoDaResposta({ r }: { r?: Rascunho }) {
  const [copiado, setCopiado] = useState(false);
  if (!r) return null;
  if (r.situacao !== 'pronto' || !r.texto) {
    return (
      <p style={{ margin: '6px 0 0', fontSize: 12, color: 'var(--ink-3)' }}>
        {POR_QUE_NAO[r.situacao as Exclude<SituacaoRascunho, 'pronto'>]}{r.motivo ? ` ${r.motivo}.` : ''}
      </p>
    );
  }
  const texto = r.texto;
  const foiPelaFila = r.envio === 'fila';
  const rotulo = foiPelaFila
    ? `Resposta do agente${r.modelo ? ` · ${r.modelo}` : ''} — ${ESTADO_DA_MENSAGEM[r.mensagem_status ?? ''] ?? 'na fila do motor'}`
    : r.envio === 'devolvido'
      ? `Voltou para você: ${r.envio_motivo ?? 'o motor não mandou'}`
      : `Rascunho do agente${r.modelo ? ` · ${r.modelo}` : ''} — não enviado`;
  return (
    <div style={{ margin: '8px 0 0', padding: '8px 10px', borderRadius: 8,
                  border: foiPelaFila ? '1px solid var(--line)' : '1px dashed var(--line)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'baseline' }}>
        <span style={{ fontSize: 11, color: r.envio === 'devolvido' ? 'var(--warn)' : 'var(--ink-3)' }}>
          {rotulo}
        </span>
        {!foiPelaFila && <button className="btn mini"
                onClick={async () => {
                  try { await navigator.clipboard.writeText(texto); } catch { /* o texto segue à vista */ }
                  setCopiado(true); setTimeout(() => setCopiado(false), 1200);
                }}>
          {copiado ? 'copiado' : 'Copiar'}
        </button>}
      </div>
      <p style={{ margin: '4px 0 0', color: 'var(--ink)', whiteSpace: 'pre-wrap' }}>{texto}</p>
    </div>
  );
}

/** Data curta e local: a pessoa lê "22/09 14:31", não um ISO com fuso. */
function quando(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}
