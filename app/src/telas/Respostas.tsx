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
 */
import { useEffect, useState } from 'react';
import { useSessao } from '../sessao';
import { Aviso, Kpi, NOME_CANAL, Secao, corCanal } from '../componentes/base';
import { lerRespostas } from '../dados';
import type { RespostaRecebida } from '../dados';
import { mensagemDeErro } from '../supabase';

export function Respostas() {
  const { tenant } = useSessao();
  const [lista, setLista] = useState<RespostaRecebida[]>([]);
  const [erro, setErro] = useState('');
  const [carregando, setCarregando] = useState(true);

  async function recarregar() {
    if (!tenant) return;
    setCarregando(true); setErro('');
    try { setLista(await lerRespostas(tenant.tenant_id)); }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }

  useEffect(() => { void recarregar(); }, [tenant?.tenant_id]);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const opt = lista.filter((r) => r.suprimido).length;

  return (
    <div className="wrap">
      <div className="cabeca"><div>
        <h1>Respostas</h1>
        <p>O que voltou dos contatos. Responder é com você, no aplicativo do canal —
           esta tela existe para você saber que há o que responder.</p>
      </div></div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <section className="kpis">
        <Kpi rotulo="Respostas" valor={lista.length}
             sub={lista.length ? 'mais recente primeiro' : 'nenhuma ainda'} />
        <Kpi rotulo="Pediram para sair" valor={opt}
             sub={opt ? 'já suprimidos' : 'nenhum'} />
        <Kpi rotulo="Em aberto" valor={lista.length - opt}
             sub="gente que respondeu e não pediu para sair" />
      </section>

      <ListaDeRespostas lista={lista} />

      <button className="btn" onClick={() => void recarregar()}>Atualizar</button>
    </div>
  );
}

/**
 * A lista, usada aqui e na tela da campanha.
 *
 * Cada resposta vem com a mensagem que a provocou. Sem isso, "sim, pode ser"
 * não quer dizer nada — e é justamente a resposta curta que é a mais comum.
 */
export function ListaDeRespostas({ lista, semCampanha }: {
  lista: RespostaRecebida[]; semCampanha?: boolean;
}) {
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

/** Data curta e local: a pessoa lê "22/09 14:31", não um ISO com fuso. */
function quando(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}
