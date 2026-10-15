/** Configurações ▸ Blacklist (D63).
 *
 * A lista é do cliente: nasce com o padrão do produto e ele edita à vontade —
 * termos, o que cada um faz, e domínios inteiros de e-mail que nunca recebem.
 *
 * Três coisas que a tela diz em voz alta, porque descobrir sozinho custa caro:
 *
 *  - supressão é permanente: apagar ou desligar um termo não devolve quem ele
 *    já suprimiu;
 *  - termo curto sem contexto casa em frase de compra ("sair" em "quero sair
 *    do meu plano") — a trava do D48 continua disponível, e a tela mostra;
 *  - "esta frase dispara o quê?" é perguntado ao classificador do banco, não
 *    reimplementado aqui.
 */
import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro } from '../supabase';
import {
  alternarDominio, apagarDominio, apagarTermoBlacklist, bloquearDominio, criarTermoBlacklist,
  lerBlacklistTermos, lerDominiosBloqueados, mudarTermoBlacklist, testarBlacklist,
} from '../dados';
import type { AcaoBlacklist, DominioBloqueado, TermoBlacklist } from '../dados';
import { Aviso, Campo, Kpi, Secao } from '../componentes/base';
import { Moldura } from './Telas';

const ACAO: Record<AcaoBlacklist, { nome: string; desc: string }> = {
  suprimir: {
    nome: 'Blacklist',
    desc: 'A pessoa nunca mais recebe nada, em canal nenhum. O CRM ouve "pediu para sair".',
  },
  identidade_invalida: {
    nome: 'Endereço errado',
    desc: 'Só este número ou e-mail sai; a pessoa continua nos outros canais. O CRM ouve "endereço inválido".',
  },
  recusa: {
    nome: 'Recusa',
    desc: 'Encerra esta cadência e não vira oportunidade. Uma campanha futura pode voltar a falar.',
  },
};

const ORDEM: AcaoBlacklist[] = ['suprimir', 'identidade_invalida', 'recusa'];

export function ConfigBlacklist() {
  const nav = useNavigate();
  const { tenant, administra } = useSessao();
  const [termos, setTermos] = useState<TermoBlacklist[]>([]);
  const [dominios, setDominios] = useState<DominioBloqueado[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState('');
  const [filtro, setFiltro] = useState<AcaoBlacklist | 'todas'>('todas');

  // Recarregar não volta para "Carregando…": desmontaria a linha que acabou
  // de mudar e o erro dela sumiria junto.
  async function recarregar() {
    try {
      const [t, d] = await Promise.all([lerBlacklistTermos(), lerDominiosBloqueados()]);
      setTermos(t); setDominios(d); setErro('');
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }
  useEffect(() => { void recarregar(); }, [tenant?.tenant_id]);

  const visiveis = useMemo(
    () => termos.filter((t) => filtro === 'todas' || t.acao === filtro),
    [termos, filtro],
  );

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const conta = (a: AcaoBlacklist) => termos.filter((t) => t.acao === a && t.ativo).length;

  return (
    <Moldura titulo="Blacklist" voltar={() => nav('/config')}
             sub="O que uma resposta precisa dizer para a pessoa sair da lista, e quem nunca recebe nada. A lista é deste cliente: nasceu com o padrão do produto e é sua para mudar.">
      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <section className="kpis">
        {ORDEM.map((a) => (
          <Kpi key={a} rotulo={ACAO[a].nome} valor={conta(a)} sub="termos ligados" />
        ))}
        <Kpi rotulo="Domínios bloqueados" valor={dominios.filter((d) => d.ativo).length}
             sub="e-mail que nunca recebe" />
      </section>

      {/* Antes da lista, não no pé: é o que a pessoa precisa saber antes de
          mexer, e não depois. */}
      <Aviso tipo="neutro">
        <b>Supressão é permanente.</b> Quem uma regra já suprimiu continua
        suprimido mesmo que você apague ou desligue o termo depois — a lista de
        supressão não aceita remoção, por nenhum caminho. Mudar a lista vale para
        as próximas respostas.
      </Aviso>

      {tenant && <Testar tenant={tenant.tenant_id} />}

      <Secao titulo="Termos nas respostas"
             nota={`${termos.length} no total · o mais específico ganha, e blacklist ganha de recusa`} />
      <div className="opts" style={{ marginBottom: 10 }}>
        {(['todas', ...ORDEM] as const).map((a) => (
          <button key={a} type="button" className="opt" aria-pressed={filtro === a}
                  onClick={() => setFiltro(a)}>
            <b>{a === 'todas' ? 'Todas' : ACAO[a].nome}</b>
            <p>{a === 'todas' ? `${termos.length} termos` : ACAO[a].desc}</p>
          </button>
        ))}
      </div>
      <section className="indice">
        {visiveis.length ? visiveis.map((t) => (
          <LinhaTermo key={t.id} termo={t} administra={administra} aoMudar={recarregar} />
        )) : <p className="vazio">Nenhum termo com esta ação.</p>}
      </section>

      {administra && tenant
        ? <NovoTermo tenant={tenant.tenant_id} existentes={termos} aoSalvar={recarregar} />
        : <Aviso tipo="neutro">Só quem administra o cliente muda a blacklist.</Aviso>}

      <Secao titulo="Domínios bloqueados"
             nota="todo e-mail do domínio e dos subdomínios — vale no envio e na fila" />
      <section className="indice">
        {dominios.length ? dominios.map((d) => (
          <LinhaDominio key={d.id} dominio={d} administra={administra} aoMudar={recarregar} />
        )) : (
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>Nenhum domínio bloqueado</b>
            <p>Concorrente, domínio da própria empresa, provedor que sempre devolve: quem estiver aqui
              não recebe e-mail deste cliente, nem o que já estava na fila.</p>
          </span></div>
        )}
      </section>
      {administra && tenant && <NovoDominio tenant={tenant.tenant_id} aoSalvar={recarregar} />}

      <Secao titulo="Pessoas e endereços específicos" />
      <div className="painel">
        <p style={{ color: 'var(--ink-2)', fontSize: 13, marginTop: 0 }}>
          Um número ou e-mail que pediu para sair por outro caminho, ou a lista de opt-out que já
          existia antes do motor, entram pela tela de supressão.
        </p>
        <button className="btn" onClick={() => nav('/supressao')}>Abrir a supressão</button>
      </div>
    </Moldura>
  );
}

/** A pergunta de quem edita a lista: "esta frase dispara o quê?". */
function Testar({ tenant }: { tenant: string }) {
  const [texto, setTexto] = useState('');
  const [res, setRes] = useState<{ termo: string; acao: AcaoBlacklist } | null | undefined>(undefined);
  const [erro, setErro] = useState('');

  async function testar(e: React.FormEvent) {
    e.preventDefault();
    setErro('');
    try { setRes(await testarBlacklist(tenant, texto)); }
    catch (e2) { setErro(mensagemDeErro(e2)); }
  }

  return (
    <form className="painel" onSubmit={testar}>
      <Campo id="bl-testar" rotulo="Testar uma resposta" valor={texto}
             aoMudar={(v) => { setTexto(v); setRes(undefined); }}
             placeholder="quero sair do meu plano atual, me manda uma proposta"
             ajuda="Escreva como a pessoa escreveria. Quem responde é o mesmo classificador que lê as respostas de verdade." />
      <button className="btn" disabled={!texto.trim()}>Testar</button>
      {erro && <Aviso tipo="erro">{erro}</Aviso>}
      {res === null && (
        <Aviso tipo="ok">
          Nenhuma regra dispara. A cadência encerra (respondeu) e a pessoa vira <b>oportunidade</b> no funil.
        </Aviso>
      )}
      {res && (
        <Aviso tipo={res.acao === 'recusa' ? 'neutro' : 'erro'}>
          Dispara <b>{ACAO[res.acao].nome}</b> pelo termo <code className="mono">{res.termo}</code>.{' '}
          {ACAO[res.acao].desc}
        </Aviso>
      )}
    </form>
  );
}

function LinhaTermo({ termo, administra, aoMudar }: {
  termo: TermoBlacklist; administra: boolean; aoMudar(): Promise<void>;
}) {
  const [mexendo, setMexendo] = useState(false);
  const [erro, setErro] = useState('');
  const [confirmando, setConfirmando] = useState(false);

  async function fazer(f: () => Promise<void>) {
    setMexendo(true); setErro('');
    try { await f(); await aoMudar(); }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setMexendo(false); setConfirmando(false); }
  }

  return (
    <div className="item" style={{ cursor: 'default', alignItems: 'flex-start', opacity: termo.ativo ? 1 : 0.6 }}>
      <span className="txt">
        <b className="mono">{termo.termo}</b>
        <p>
          {termo.exige_uma_de
            ? <>só conta com <i>{termo.exige_uma_de.join(', ')}</i> nas três palavras seguintes</>
            : 'vale sozinho'}
          {termo.nota ? ` · ${termo.nota}` : ''}
        </p>
        <span className="chips" style={{ marginTop: 6 }}>
          <span className="chip">{ACAO[termo.acao].nome}</span>
          <span className="chip">{termo.origem === 'padrao' ? 'padrão do produto' : 'seu'}</span>
          {!termo.ativo && <span className="chip">desligado</span>}
        </span>
        {administra && (
          <p style={{ marginTop: 8, display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
            <select aria-label={`Ação de ${termo.termo}`} value={termo.acao} disabled={mexendo}
                    style={{ fontSize: 12, padding: '3px 6px', borderRadius: 7 }}
                    onChange={(e) => void fazer(() => mudarTermoBlacklist(termo.id, { acao: e.target.value as AcaoBlacklist }))}>
              {ORDEM.map((a) => <option key={a} value={a}>{ACAO[a].nome}</option>)}
            </select>
            <button className="btn mini" disabled={mexendo}
                    onClick={() => void fazer(() => mudarTermoBlacklist(termo.id, { ativo: !termo.ativo }))}>
              {termo.ativo ? 'Desligar' : 'Ligar'}
            </button>
            {!confirmando ? (
              <button className="btn mini" disabled={mexendo}
                      onClick={() => setConfirmando(true)}>Apagar</button>
            ) : (
              <>
                <button className="btn mini" style={{ color: 'var(--crit)' }}
                        disabled={mexendo} onClick={() => void fazer(() => apagarTermoBlacklist(termo.id))}>
                  Confirmar
                </button>
                <button className="btn mini"
                        onClick={() => setConfirmando(false)}>Cancelar</button>
              </>
            )}
          </p>
        )}
        {erro && <p style={{ color: 'var(--crit)', fontSize: 11 }}>{erro}</p>}
      </span>
    </div>
  );
}

function NovoTermo({ tenant, existentes, aoSalvar }: {
  tenant: string; existentes: TermoBlacklist[]; aoSalvar(): Promise<void>;
}) {
  const [termo, setTermo] = useState('');
  const [contexto, setContexto] = useState('');
  const [acao, setAcao] = useState<AcaoBlacklist>('suprimir');
  const [nota, setNota] = useState('');
  const [estado, setEstado] = useState<'parado' | 'salvando'>('parado');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  const palavras = contexto.split(',').map((c) => c.trim()).filter(Boolean);
  // Só um aviso, não uma trava: a decisão é de quem configura. Mas uma
  // palavra só, sem contexto, suprimindo, é exatamente o erro que o D48
  // documentou — e ele não dá erro, dá um cliente apagado.
  const arriscado = acao === 'suprimir' && !palavras.length && termo.trim().split(/\s+/).length === 1
    && termo.trim().length > 0;

  async function salvar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null); setEstado('salvando');
    try {
      await criarTermoBlacklist({ tenant, termo, contexto: palavras, acao, nota });
      setMsg({ tipo: 'ok', texto: `"${termo.trim()}" entrou na lista.` });
      setTermo(''); setContexto(''); setNota('');
      await aoSalvar();
    } catch (e2) {
      const m = mensagemDeErro(e2);
      setMsg({ tipo: 'erro', texto: m.includes('termo_uk') || m.includes('duplicate')
        ? 'Esse termo já está na lista — mude a ação dele lá em cima.' : m });
    } finally { setEstado('parado'); }
  }

  return (
    <form className="painel" onSubmit={salvar} style={{ marginTop: 12 }}>
      <b style={{ display: 'block', marginBottom: 10 }}>Acrescentar termo</b>
      <Campo id="bl-termo" rotulo="Termo" valor={termo} aoMudar={setTermo}
             placeholder="não me ligue"
             ajuda="Maiúscula, acento e pontuação não importam: o banco grava na forma em que compara." />
      <Campo id="bl-ctx" rotulo="Só conta se vier com" valor={contexto} aoMudar={setContexto}
             obrigatorio={false} placeholder="lista, cadastro, receber"
             ajuda="Separadas por vírgula. O termo só dispara se uma delas aparecer nas três palavras seguintes — é o que separa “sair da lista” de “sair do meu plano”." />
      <div className="campo">
        <label htmlFor="bl-acao">O que acontece</label>
        <select id="bl-acao" value={acao} onChange={(e) => setAcao(e.target.value as AcaoBlacklist)}>
          {ORDEM.map((a) => <option key={a} value={a}>{ACAO[a].nome} — {ACAO[a].desc}</option>)}
        </select>
      </div>
      <Campo id="bl-nota" rotulo="Por que" valor={nota} aoMudar={setNota} obrigatorio={false}
             placeholder="cliente pediu depois de reclamação no Reclame Aqui" />
      {arriscado && (
        <Aviso tipo="neutro">
          <b>Uma palavra só, sem contexto, suprimindo.</b> Ela vai casar em qualquer resposta que a
          contenha — “sair” casaria “quero sair do meu plano”, que é o melhor lead que existe. Se o
          termo tiver outra leitura, preencha o campo de contexto.
        </Aviso>
      )}
      {existentes.some((t) => t.termo === termo.trim().toLowerCase()) && (
        <Aviso tipo="neutro">Esse termo já existe — mude a ação dele na lista.</Aviso>
      )}
      {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
      <button className="btn prim" disabled={estado === 'salvando' || !termo.trim()}>
        {estado === 'salvando' ? 'Salvando…' : 'Acrescentar'}
      </button>
    </form>
  );
}

function LinhaDominio({ dominio, administra, aoMudar }: {
  dominio: DominioBloqueado; administra: boolean; aoMudar(): Promise<void>;
}) {
  const [mexendo, setMexendo] = useState(false);
  const [erro, setErro] = useState('');

  async function fazer(f: () => Promise<void>) {
    setMexendo(true); setErro('');
    try { await f(); await aoMudar(); }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setMexendo(false); }
  }

  return (
    <div className="item" style={{ cursor: 'default', opacity: dominio.ativo ? 1 : 0.6 }}>
      <span className="txt">
        <b className="mono">@{dominio.dominio}</b>
        <p>{dominio.nota ?? 'e todos os subdomínios'}{dominio.ativo ? '' : ' · desligado'}</p>
        {erro && <p style={{ color: 'var(--crit)', fontSize: 11 }}>{erro}</p>}
      </span>
      {administra && (
        <span style={{ display: 'flex', gap: 6 }}>
          <button className="btn mini" disabled={mexendo}
                  onClick={() => void fazer(() => alternarDominio(dominio.id, !dominio.ativo))}>
            {dominio.ativo ? 'Desligar' : 'Ligar'}
          </button>
          <button className="btn mini" disabled={mexendo}
                  onClick={() => void fazer(() => apagarDominio(dominio.id))}>
            Apagar
          </button>
        </span>
      )}
    </div>
  );
}

function NovoDominio({ tenant, aoSalvar }: { tenant: string; aoSalvar(): Promise<void> }) {
  const [dominio, setDominio] = useState('');
  const [nota, setNota] = useState('');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);
  const [estado, setEstado] = useState<'parado' | 'salvando'>('parado');

  async function salvar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null); setEstado('salvando');
    try {
      await bloquearDominio({ tenant, dominio, nota });
      setMsg({ tipo: 'ok', texto: 'Bloqueado. O que estava na fila para esse domínio também não sai.' });
      setDominio(''); setNota('');
      await aoSalvar();
    } catch (e2) {
      const m = mensagemDeErro(e2);
      setMsg({ tipo: 'erro', texto: m.includes('formato') ? 'Isso não parece um domínio — algo como concorrente.com.br.'
        : m.includes('dominio_uk') || m.includes('duplicate') ? 'Esse domínio já está bloqueado.' : m });
    } finally { setEstado('parado'); }
  }

  return (
    <form className="painel" onSubmit={salvar} style={{ marginTop: 12 }}>
      <Campo id="bl-dom" rotulo="Bloquear domínio" valor={dominio} aoMudar={setDominio} mono
             placeholder="concorrente.com.br" ajuda="Com ou sem @. Vale também para os subdomínios." />
      <Campo id="bl-dom-nota" rotulo="Por que" valor={nota} aoMudar={setNota} obrigatorio={false} />
      {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
      <button className="btn prim" disabled={estado === 'salvando' || !dominio.trim()}>
        {estado === 'salvando' ? 'Salvando…' : 'Bloquear'}
      </button>
    </form>
  );
}
