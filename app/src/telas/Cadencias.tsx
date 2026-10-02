/** Escrever a cadência (D55).
 *
 * Até aqui a única forma de existir uma cadência era instanciar um dos sete
 * modelos do catálogo. Quem quisesse a oitava não tinha tela — o schema
 * inteiro existia (`flows`, `flow_versions`, `flow_steps`) e não tinha porta.
 *
 * Duas coisas que esta tela precisa dizer o tempo todo, porque as duas são
 * decisões antigas que a pessoa não tem como adivinhar:
 *
 *   * **editar é publicar a versão seguinte** (D9). Não há como alterar uma
 *     versão publicada — o banco recusa por gatilho. Quem já está inscrito
 *     termina na versão em que entrou, e isso é a garantia, não um efeito
 *     colateral;
 *   * **publicar não reponta campanha nenhuma.** A campanha continua rodando
 *     a versão que ela apontava, e trocar é um ato à parte, campanha por
 *     campanha, porque é ali que a conferência de canais do D47 acontece. A
 *     tela mostra quantas ficaram para trás: o que se evita é o silêncio, não
 *     a troca.
 */
import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useSessao } from '../sessao';
import { Aviso, Campo, LinhaIndice, NOME_CANAL, Secao, corCanal } from '../componentes/base';
import {
  definirFlowDaCampanha, lerCampanhas, lerCanaisEntregaveis, lerPassosDaVersao,
  lerVariaveisDisponiveis, lerVersoesDeFlow, publicarVersaoDeFlow,
} from '../dados';
import type {
  Campanha, CanalEntregavel, PassoDeFlow, VariavelDisponivel, VersaoDeFlow,
} from '../dados';
import { mensagemDeErro } from '../supabase';
import { variaveisDoTexto } from '../variaveis';

const CANAIS = ['whatsapp', 'email', 'sms', 'instagram'] as const;

interface Rascunho { canal: string; atraso: string; template: string }

const VAZIO: Rascunho = { canal: 'whatsapp', atraso: '24', template: '' };

// ---------------------------------------------------------------------------
// Índice
// ---------------------------------------------------------------------------

export function Cadencias() {
  const nav = useNavigate();
  const { tenant, opera } = useSessao();
  const [versoes, setVersoes] = useState<VersaoDeFlow[]>([]);
  const [campanhas, setCampanhas] = useState<Campanha[]>([]);
  const [erro, setErro] = useState('');
  const [carregando, setCarregando] = useState(true);

  useEffect(() => {
    Promise.all([lerVersoesDeFlow(), lerCampanhas()])
      .then(([v, c]) => { setVersoes(v); setCampanhas(c); })
      .catch((e) => setErro(mensagemDeErro(e)))
      .finally(() => setCarregando(false));
  }, [tenant?.tenant_id]);

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  // Uma linha por cadência, mostrando a versão mais recente. As anteriores não
  // somem — continuam rodando para quem entrou nelas —, mas não é por elas que
  // se começa a ler.
  const porFlow = new Map<string, VersaoDeFlow[]>();
  for (const v of versoes) {
    porFlow.set(v.flow_id, [...(porFlow.get(v.flow_id) ?? []), v]);
  }
  const cadencias = [...porFlow.entries()].map(([flowId, vs]) => {
    const ordenadas = [...vs].sort((a, b) => b.versao - a.versao);
    return { flowId, ultima: ordenadas[0]!, todas: ordenadas };
  });

  const emUso = (versaoId: string) =>
    campanhas.filter((c) => c.flow_version_id === versaoId).length;

  return (
    <div className="wrap">
      <div className="cabeca"><div>
        <h1>Cadências</h1>
        <p>A sequência de toques que uma campanha roda. Editar uma cadência publica a
           <b> versão seguinte</b>: quem já está inscrito termina na versão em que entrou,
           e é isso que impede uma correção de texto de mudar a conversa no meio.</p>
      </div></div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <Secao titulo="Suas cadências"
             nota={cadencias.length ? `${cadencias.length} no total` : 'nenhuma ainda'} />
      <section className="indice">
        {cadencias.length ? cadencias.map(({ flowId, ultima, todas }) => {
          const usos = todas.reduce((n, v) => n + emUso(v.id), 0);
          return (
            <LinhaIndice
              key={flowId} icone="modelo" cor={corCanal(ultima.canais[0] ?? '')}
              titulo={ultima.flow_nome}
              descricao={
                `v${ultima.versao} · ${ultima.passos} ${ultima.passos === 1 ? 'passo' : 'passos'} · `
                + `${ultima.canais.map((c) => NOME_CANAL[c] ?? c).join(', ')}`
                + (todas.length > 1 ? ` · ${todas.length} versões publicadas` : '')
              }
              contagem={usos ? `${usos} campanha${usos === 1 ? '' : 's'}` : 'sem campanha'}
              aoClicar={() => nav(`/cadencias/${flowId}`)}
            />
          );
        }) : (
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>Nenhuma cadência escrita ainda</b>
            <p>As campanhas criadas a partir de um modelo já trazem a sua — ela aparece
               aqui assim que existir. Abaixo dá para escrever uma do zero.</p>
          </span></div>
        )}
      </section>

      {opera && (
        <section className="indice">
          <LinhaIndice
            icone="modelo" titulo="Escrever uma cadência nova"
            descricao="passo a passo, com o canal e o intervalo de cada toque"
            contagem="nova" aoClicar={() => nav('/cadencias/nova')}
          />
        </section>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

export function Cadencia() {
  const { id = '' } = useParams();
  const nav = useNavigate();
  const { tenant, opera } = useSessao();
  const nova = id === 'nova';

  const [versoes, setVersoes] = useState<VersaoDeFlow[]>([]);
  const [campanhas, setCampanhas] = useState<Campanha[]>([]);
  const [variaveis, setVariaveis] = useState<VariavelDisponivel[]>([]);
  const [entregaveis, setEntregaveis] = useState<CanalEntregavel[]>([]);
  const [nome, setNome] = useState('');
  const [passos, setPassos] = useState<Rascunho[]>([{ ...VAZIO, atraso: '0' }]);
  const [carregando, setCarregando] = useState(true);
  const [publicando, setPublicando] = useState(false);
  const [erro, setErro] = useState('');
  const [feito, setFeito] = useState<{ versao: number; versaoId: string } | null>(null);

  async function carregar() {
    if (!tenant) return;
    // Recarregar volta a "carregando" de propósito: depois de publicar uma
    // cadência nova a rota troca de `/cadencias/nova` para `/cadencias/<id>`,
    // e sem isto a tela renderiza "Cadência não encontrada" no meio do
    // caminho — a versão existe, só ainda não chegou.
    setCarregando(true);
    setErro('');
    try {
      const [vs, cs, vars, ent] = await Promise.all([
        lerVersoesDeFlow(), lerCampanhas(),
        lerVariaveisDisponiveis(tenant.tenant_id), lerCanaisEntregaveis(),
      ]);
      setVersoes(vs); setCampanhas(cs); setVariaveis(vars); setEntregaveis(ent);

      if (!nova) {
        const desta = vs.filter((v) => v.flow_id === id).sort((a, b) => b.versao - a.versao);
        const ultima = desta[0];
        if (ultima) {
          setNome(ultima.flow_nome);
          // Parte-se sempre da versão mais recente: editar é continuar de onde
          // a cadência está, não de uma folha em branco.
          const ps: PassoDeFlow[] = await lerPassosDaVersao(ultima.id);
          setPassos(ps.map((p) => ({
            canal: p.canal, atraso: String(p.atraso_horas), template: p.template,
          })));
        }
      }
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }

  useEffect(() => { void carregar(); }, [tenant?.tenant_id, id]);

  const desta = useMemo(
    () => versoes.filter((v) => v.flow_id === id).sort((a, b) => b.versao - a.versao),
    [versoes, id],
  );
  const ultima = desta[0] ?? null;

  const motivoDe = (canal: string) =>
    entregaveis.find((e) => e.canal === canal)?.motivo ?? 'sem_adapter';

  const chavesConhecidas = new Set(variaveis.map((v) => v.chave));
  const usadas = [...new Set(passos.flatMap((p) => variaveisDoTexto(p.template)))];
  const inventadas = usadas.filter((u) => !chavesConhecidas.has(u));
  const canaisUsados = [...new Set(passos.map((p) => p.canal))];
  const semEntrega = canaisUsados.filter((c) => motivoDe(c) !== 'entrega');

  function mexer(i: number, campo: keyof Rascunho, valor: string) {
    setPassos((ps) => ps.map((p, j) => (j === i ? { ...p, [campo]: valor } : p)));
    setFeito(null);
  }

  function mover(i: number, delta: number) {
    setPassos((ps) => {
      const j = i + delta;
      if (j < 0 || j >= ps.length) return ps;
      const n = [...ps];
      const a = n[i]!; const b = n[j]!;
      n[i] = b; n[j] = a;
      return n;
    });
    setFeito(null);
  }

  async function publicar() {
    if (!tenant) return;
    setPublicando(true); setErro(''); setFeito(null);
    try {
      const r = await publicarVersaoDeFlow({
        tenant: tenant.tenant_id,
        flowId: nova ? null : id,
        nome: nova ? nome : null,
        passos: passos.map((p, i) => ({
          canal: p.canal,
          // O primeiro passo sai quando a inscrição vence; o motor nunca lê o
          // atraso dele. Mandar 0 aqui é dizer a mesma coisa que a função faz.
          atraso_horas: i === 0 ? 0 : Number(p.atraso || 0),
          template: p.template,
        })),
      });
      setFeito({ versao: r.versao, versaoId: r.flow_version_id });
      if (nova) { nav(`/cadencias/${r.flow_id}`, { replace: true }); }
      await carregar();
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setPublicando(false); }
  }

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;
  if (!nova && !ultima) {
    return <div className="wrap"><Aviso tipo="erro">Cadência não encontrada.</Aviso></div>;
  }

  const podePublicar = opera && passos.length > 0
    && passos.every((p) => p.template.trim())
    && (!nova || nome.trim());

  return (
    <div className="wrap">
      <div className="cabeca"><div>
        <button className="voltar" onClick={() => nav('/cadencias')}>← Cadências</button>
        <h1>{nova ? 'Cadência nova' : nome}</h1>
        <p>
          {nova
            ? 'Cada passo é um toque: o canal por onde sai, quanto tempo depois do anterior, e o texto.'
            : `Publicada até a v${ultima!.versao}. Salvar aqui cria a v${ultima!.versao + 1} — `
              + 'a anterior continua existindo, e quem está inscrito nela termina nela (D9).'}
        </p>
      </div></div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      {feito && (
        <Aviso tipo="ok">
          <b>Versão {feito.versao} publicada.</b>{' '}
          Ela ainda não está rodando em campanha nenhuma — trocar é decisão de cada
          campanha, logo abaixo.
        </Aviso>
      )}

      {nova && (
        <div className="painel">
          <Campo id="cad-nome" rotulo="Nome da cadência" valor={nome} aoMudar={setNome}
                 ajuda="Como você vai reconhecê-la na lista. Pode ser trocado publicando outra." />
        </div>
      )}

      <Secao titulo="Os passos" nota={`${passos.length} ${passos.length === 1 ? 'toque' : 'toques'}`} />

      {passos.map((p, i) => (
        <div className="painel" key={i}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: 6 }}>
            <b style={{ color: corCanal(p.canal) }}>Passo {i + 1}</b>
            {opera && (
              <>
                <button className="btn" style={{ fontSize: 11, padding: '2px 7px' }}
                        disabled={i === 0} onClick={() => mover(i, -1)}>subir</button>
                <button className="btn" style={{ fontSize: 11, padding: '2px 7px' }}
                        disabled={i === passos.length - 1} onClick={() => mover(i, 1)}>descer</button>
                <button className="btn" style={{ fontSize: 11, padding: '2px 7px' }}
                        disabled={passos.length === 1}
                        onClick={() => { setPassos((ps) => ps.filter((_, j) => j !== i)); setFeito(null); }}>
                  remover
                </button>
              </>
            )}
          </div>

          <div className="campo">
            <label htmlFor={`p-canal-${i}`}>Canal</label>
            <select id={`p-canal-${i}`} value={p.canal} disabled={!opera}
                    onChange={(e) => mexer(i, 'canal', e.target.value)}>
              {CANAIS.map((c) => (
                <option key={c} value={c}>
                  {NOME_CANAL[c] ?? c}
                  {motivoDe(c) === 'sem_adapter' ? ' — sem adapter' : ''}
                  {motivoDe(c) === 'sem_remetente' ? ' — sem remetente' : ''}
                </option>
              ))}
            </select>
          </div>

          <div className="campo">
            <label htmlFor={`p-atraso-${i}`}>
              {i === 0 ? 'Quando sai' : 'Horas depois do passo anterior'}
            </label>
            {i === 0 ? (
              // Não é um campo desabilitado: é um fato. O agendador usa o
              // atraso do passo SEGUINTE para marcar o próximo disparo, então
              // o do primeiro nunca é lido. Aceitar um número aqui seria
              // guardar o que não tem efeito.
              <p style={{ color: 'var(--ink-2)', fontSize: 13, margin: '2px 0 0' }}>
                Assim que a inscrição vencer. O motor não lê atraso no primeiro
                passo — quem marca a hora do primeiro toque é a inscrição.
              </p>
            ) : (
              <input id={`p-atraso-${i}`} className="mono" inputMode="numeric"
                     value={p.atraso} disabled={!opera}
                     onChange={(e) => mexer(i, 'atraso', e.target.value)} />
            )}
          </div>

          <div className="campo">
            <label htmlFor={`p-texto-${i}`}>Texto</label>
            <textarea id={`p-texto-${i}`} rows={3} value={p.template} disabled={!opera}
                      onChange={(e) => mexer(i, 'template', e.target.value)}
                      placeholder="Oi {{nome}}, aqui é da Afinix." />
            <span className="ajuda">
              {'{{chave}}'} vira o valor do contato. Sem valor, a marcação é apagada — o
              texto fica &ldquo;Olá ,&rdquo;, que é o rastro que a tela da campanha marca depois.
            </span>
          </div>
        </div>
      ))}

      {opera && (
        <button className="btn" onClick={() => { setPassos((ps) => [...ps, { ...VAZIO }]); setFeito(null); }}>
          Acrescentar passo
        </button>
      )}

      <Variaveis disponiveis={variaveis} usadas={usadas} inventadas={inventadas} />

      {semEntrega.length > 0 && (
        <Aviso tipo="neutro">
          Passo em {semEntrega.map((c) => NOME_CANAL[c] ?? c).join(', ')}:{' '}
          {semEntrega.map((c) => motivoDe(c)).includes('sem_adapter')
            ? 'nenhum provedor deste canal sabe enviar hoje, e isso não é configuração que falta.'
            : 'este cliente ainda não tem remetente neste canal.'}{' '}
          A cadência publica do mesmo jeito — o motor adia o passo em vez de queimá-lo (D31) —
          mas enquanto isso durar o toque não sai.
        </Aviso>
      )}

      {opera && (
        <div className="painel">
          <button className="btn prim" disabled={!podePublicar || publicando}
                  onClick={() => void publicar()}>
            {publicando ? 'Publicando…'
              : nova ? 'Publicar a versão 1' : `Publicar a v${ultima!.versao + 1}`}
          </button>
          <span className="ajuda" style={{ marginLeft: 9 }}>
            Publicar não altera nada do que já está rodando: cria a versão seguinte.
          </span>
        </div>
      )}

      {!nova && (
        <QuemRoda flowVersoes={desta} campanhas={campanhas}
                  aoMudar={carregar} aoFalhar={setErro} podeOperar={opera} />
      )}
    </div>
  );
}

/**
 * As variáveis, dos dois lados: as que a base tem, e as que o texto pede.
 *
 * A que o texto pede e a base não tem é o erro que não dá erro — `renderizar`
 * apaga a marcação e a frase sai truncada. Mostrar isso aqui é o aviso do D42
 * antes do disparo, em vez de depois.
 */
function Variaveis({ disponiveis, usadas, inventadas }: {
  disponiveis: VariavelDisponivel[]; usadas: string[]; inventadas: string[];
}) {
  return (
    <>
      <Secao titulo="Variáveis" nota={`${disponiveis.length} disponíveis nesta base`} />
      <div className="painel">
        {disponiveis.length === 0 ? (
          <p className="vazio" style={{ margin: 0 }}>
            Nenhuma ainda: a base não tem contato com nome nem com dado extra.
          </p>
        ) : (
          <div className="chips">
            {disponiveis.map((v) => (
              <span key={v.chave} className="chip" title={`${v.contatos} contato(s) têm`}>
                <code className="mono">{`{{${v.chave}}}`}</code>
                <span style={{ marginLeft: 5, color: 'var(--ink-3)' }}>{v.contatos}</span>
              </span>
            ))}
          </div>
        )}

        {inventadas.length > 0 && (
          <Aviso tipo="erro">
            O texto pede {inventadas.map((v) => <code key={v} className="mono">{`{{${v}}}`}</code>)
              .reduce((a, b) => <>{a}, {b}</>)}{' '}
            e nenhum contato desta base tem essa chave. O motor não erra: ele
            <b> apaga</b> a marcação, e a frase sai sem o pedaço. Preencha o dado na
            importação, ou escreva uma frase que funcione sem ele.
          </Aviso>
        )}

        {usadas.length > 0 && inventadas.length === 0 && (
          <p style={{ color: 'var(--ink-2)', fontSize: 13, marginBottom: 0 }}>
            O texto usa {usadas.map((u) => `{{${u}}}`).join(', ')} — todas existem na base.
            Contato que não tiver a chave preenchida ainda sai com a marcação apagada.
          </p>
        )}
      </div>
    </>
  );
}

/**
 * Quem roda o quê, e o convite para repontar.
 *
 * É o ponto onde publicar deixa de ser silencioso. Sem esta seção, a pessoa
 * edita a cadência, publica a v2 e vai embora achando que mudou algo — quando
 * a campanha continua na v1, corretamente e sem avisar.
 */
function QuemRoda({ flowVersoes, campanhas, aoMudar, aoFalhar, podeOperar }: {
  flowVersoes: VersaoDeFlow[]; campanhas: Campanha[];
  aoMudar(): Promise<void>; aoFalhar(m: string): void; podeOperar: boolean;
}) {
  const [mexendo, setMexendo] = useState('');
  const ultima = flowVersoes[0];
  if (!ultima) return null;

  const ids = new Set(flowVersoes.map((v) => v.id));
  const usando = campanhas.filter((c) => c.flow_version_id && ids.has(c.flow_version_id));
  const atrasadas = usando.filter((c) => c.flow_version_id !== ultima.id);

  async function repontar(campanha: string) {
    setMexendo(campanha); aoFalhar('');
    try { await definirFlowDaCampanha(campanha, ultima!.id); await aoMudar(); }
    catch (e) { aoFalhar(mensagemDeErro(e)); }
    finally { setMexendo(''); }
  }

  return (
    <>
      <Secao titulo="Quem roda esta cadência"
             nota={usando.length ? `${usando.length} campanha(s)` : 'nenhuma campanha ainda'} />
      <div className="painel">
        {usando.length === 0 ? (
          <p className="vazio" style={{ margin: 0 }}>
            Nenhuma campanha aponta esta cadência. Abra a campanha e escolha-a lá.
          </p>
        ) : (
          <table className="tab">
            <thead><tr><th>Campanha</th><th>Versão que roda</th><th /></tr></thead>
            <tbody>
              {usando.map((c) => {
                const v = flowVersoes.find((x) => x.id === c.flow_version_id);
                const naUltima = c.flow_version_id === ultima.id;
                return (
                  <tr key={c.id}>
                    <td style={{ color: 'var(--ink)' }}>{c.nome}</td>
                    <td>
                      v{v?.versao ?? '?'}
                      {naUltima ? '' : ` — a mais recente é a v${ultima.versao}`}
                    </td>
                    <td>
                      {!naUltima && podeOperar && (
                        <button className="btn" style={{ fontSize: 11, padding: '3px 8px' }}
                                disabled={!!mexendo} onClick={() => void repontar(c.id)}>
                          {mexendo === c.id ? 'um instante…' : `Passar para a v${ultima.versao}`}
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}

        {atrasadas.length > 0 && (
          <Aviso tipo="neutro">
            <b>{atrasadas.length}</b>{' '}
            {atrasadas.length === 1 ? 'campanha continua' : 'campanhas continuam'} na versão
            anterior, e isso é o comportamento correto: publicar não reponta ninguém.
            Passar para a v{ultima.versao} vale para quem for inscrito <b>a partir</b> da
            troca — quem já está em cadência termina na versão em que entrou (D9). Cada
            troca é conferida à parte, porque a versão nova pode não tocar um canal que a
            campanha habilita (D47).
          </Aviso>
        )}
      </div>
    </>
  );
}
