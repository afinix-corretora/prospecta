/** O funil, em Kanban (D57).
 *
 * O motor sempre soube o que aconteceu com cada contato. O que faltava era
 * dizer **onde ele está** — quantos em prospecção, quantos responderam,
 * quantos viraram oportunidade.
 *
 * Duas coisas que esta tela leva da base de conhecimento da casa, onde o
 * padrão está catalogado em sete projetos anteriores:
 *
 *   * **o estágio é identificado por `slug`, nunca por nome.** Renomear
 *     "Respondeu" para "Lead quente" não quebra nada, porque nenhum código
 *     aqui procura pelo rótulo. Dois projetos quebraram assim;
 *   * **mover é uma chamada, não um UPDATE.** `mover_deal` grava a atividade
 *     e recusa que automação tire card de ganho ou de perdido. O cliente não
 *     tem privilégio de UPDATE em `deals` — a porta é única de verdade.
 *
 * Arrastar usa o drag-and-drop nativo do navegador, sem biblioteca. Ele é
 * suficiente para colunas e cards, e todo card também tem um seletor de
 * destino — que é o que funciona no celular e no teclado.
 */
import { useEffect, useMemo, useState } from 'react';
import { useSessao } from '../sessao';
import { Aviso, Kpi, Secao } from '../componentes/base';
import { lerCards, lerEstagios, moverCard } from '../dados';
import type { Card, Estagio } from '../dados';
import { mensagemDeErro } from '../supabase';

/** O que cada estágio do funil padrão significa, em uma linha. */
const EXPLICA: Record<string, string> = {
  em_prospeccao: 'inscrito, nada saiu ainda',
  contatado: 'recebeu ao menos uma mensagem de verdade',
  respondeu: 'respondeu — a cadência dele foi encerrada',
  sem_resposta: 'a cadência acabou e ninguém respondeu',
  oportunidade: 'respondeu e não recusou',
  opt_out: 'pediu para sair — não fale com esta pessoa',
};

export function Funil() {
  const { tenant, opera } = useSessao();
  const [estagios, setEstagios] = useState<Estagio[]>([]);
  const [cards, setCards] = useState<Card[]>([]);
  const [erro, setErro] = useState('');
  const [carregando, setCarregando] = useState(true);
  const [arrastando, setArrastando] = useState<string | null>(null);
  const [sobre, setSobre] = useState<string | null>(null);

  async function recarregar() {
    if (!tenant) return;
    setErro('');
    try {
      const [es, cs] = await Promise.all([lerEstagios(), lerCards()]);
      setEstagios(es);
      setCards(cs);
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }

  useEffect(() => { void recarregar(); }, [tenant?.tenant_id]);

  const porEstagio = useMemo(() => {
    const m = new Map<string, Card[]>();
    for (const e of estagios) m.set(e.id, []);
    for (const c of cards) m.get(c.stage_id)?.push(c);
    return m;
  }, [estagios, cards]);

  async function mover(deal: string, slug: string) {
    setErro('');
    try {
      const moveu = await moverCard(deal, slug, 'movido na tela');
      if (!moveu) {
        setErro('O card não se moveu. Ele já estava neste estágio.');
      }
      await recarregar();
    } catch (e) { setErro(mensagemDeErro(e)); }
  }

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  if (estagios.length === 0) {
    return (
      <div className="wrap">
        <div className="cabeca"><div><h1>Funil</h1></div></div>
        <div className="painel">
          <p className="vazio" style={{ margin: 0 }}>
            O funil ainda não existe. Ele nasce sozinho na primeira inscrição em
            campanha — não há nada para configurar antes.
          </p>
        </div>
      </div>
    );
  }

  const total = cards.length;
  const ganhos = cards.filter((c) => estagios.find((e) => e.id === c.stage_id)?.tipo === 'ganho').length;
  const abertos = cards.filter((c) => estagios.find((e) => e.id === c.stage_id)?.tipo === 'aberto').length;

  return (
    <div className="wrap">
      <div className="cabeca"><div>
        <h1>Funil</h1>
        <p>Onde cada lead está. O motor move sozinho conforme os fatos acontecem;
           você move arrastando quando souber algo que ele não sabe.</p>
      </div></div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <section className="kpis">
        <Kpi rotulo="Leads no funil" valor={total} sub={total ? 'no total' : 'nenhum ainda'} />
        <Kpi rotulo="Em aberto" valor={abertos} sub="ainda em jogo" />
        <Kpi rotulo="Oportunidades" valor={ganhos} sub="resposta positiva" />
      </section>

      <div className="kanban">
        {estagios.map((e) => {
          const lista = porEstagio.get(e.id) ?? [];
          return (
            <div
              key={e.id}
              className="coluna"
              data-sobre={sobre === e.id ? 'true' : undefined}
              onDragOver={(ev) => { if (opera && arrastando) { ev.preventDefault(); setSobre(e.id); } }}
              onDragLeave={() => setSobre((s) => (s === e.id ? null : s))}
              onDrop={(ev) => {
                ev.preventDefault();
                setSobre(null);
                if (arrastando) void mover(arrastando, e.slug);
                setArrastando(null);
              }}
            >
              <div className="coluna-topo">
                <b style={{ color: e.cor ?? 'var(--ink)' }}>{e.nome}</b>
                <span className="cont">{lista.length}</span>
              </div>
              <p className="coluna-nota">{EXPLICA[e.slug] ?? ''}</p>

              {/* Desde o D58 o classificador preenche esta coluna: resposta
                  que não é recusa vira oportunidade. A frase anterior dizia
                  que nada a alimentava, e ficou falsa no mesmo dia — é o
                  oposto do defeito que a base da casa registra, e custa a
                  mesma confiança. */}
              {e.tipo === 'ganho' && lista.length === 0 && (
                <p className="coluna-vazia">
                  Vazia porque ninguém respondeu ainda. Quando alguém responder
                  sem recusar, o card chega aqui sozinho.
                </p>
              )}

              {lista.map((c) => (
                <div
                  key={c.id}
                  className="card"
                  draggable={opera}
                  onDragStart={() => setArrastando(c.id)}
                  onDragEnd={() => { setArrastando(null); setSobre(null); }}
                >
                  <b>{c.contato}</b>
                  {c.campanha && <span className="card-campanha">{c.campanha}</span>}
                  <span className="card-rodape">
                    {quando(c.entrou_no_estagio_em)}
                    {c.movido_por === 'pessoa' && ' · movido à mão'}
                    {c.movido_por === 'ia' && ' · movido pela IA'}
                  </span>

                  {opera && (
                    <select
                      className="card-mover"
                      value=""
                      onChange={(ev) => { if (ev.target.value) void mover(c.id, ev.target.value); }}
                      aria-label={`Mover ${c.contato} para outro estágio`}
                    >
                      <option value="">mover para…</option>
                      {estagios.filter((x) => x.id !== e.id).map((x) => (
                        <option key={x.id} value={x.slug}>{x.nome}</option>
                      ))}
                    </select>
                  )}
                </div>
              ))}
            </div>
          );
        })}
      </div>

      <Secao titulo="Como o motor move" />
      <div className="painel">
        <p style={{ color: 'var(--ink-2)', fontSize: 13, marginTop: 0 }}>
          Inscrever põe em <b>Em prospecção</b>. A primeira mensagem que sai de
          verdade move para <b>Contatado</b> — em shadow mode nada se move, porque
          ninguém foi contatado. Responder move para <b>Respondeu</b>; a cadência
          acabar sem resposta move para <b>Sem resposta</b>; pedir para sair move
          para <b>Pediu para sair</b>.
        </p>
        <p style={{ color: 'var(--ink-2)', fontSize: 13 }}>
          E quem responde sem recusar vai direto para <b>Oportunidade</b>. O motor
          não tenta adivinhar se a resposta foi entusiasmada — ele pergunta
          apenas <b>&ldquo;isto é uma recusa?&rdquo;</b>, e a dúvida conta como não.
          Descartar um card que não servia custa dois segundos; perder um lead bom
          é silencioso. Quem recusa fica em <b>Respondeu</b> e <b>não</b> é
          suprimido — recusar esta oferta não é pedir para nunca mais ser contatado.
        </p>
        <p style={{ color: 'var(--ink-2)', fontSize: 13, marginBottom: 0 }}>
          Uma campanha nova traz de volta para prospecção quem estava em <b>Sem
          resposta</b> — mas <b>nunca</b> quem pediu para sair. E o motor nunca tira
          um card de <b>Oportunidade</b>: só você faz isso.
        </p>
      </div>

      <button className="btn" onClick={() => void recarregar()}>Atualizar</button>
    </div>
  );
}

function quando(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}
