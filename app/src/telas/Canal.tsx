import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useSessao } from '../sessao';
import { mensagemDeErro, BASE_FUNCOES } from '../supabase';
import {
  alternarRemetente, criarRemetente, lerProvedoresCanal, lerRemetentes, lerServidores,
  provisionarInstancia, salvarCredencial, salvarServidor,
} from '../dados';
import type { ProvedorCanal, Remetente, Servidor } from '../dados';
import {
  Aviso, Campo, Copiar, Icone, Kpi, LinhaIndice, NOME_CANAL, Secao, corCanal,
} from '../componentes/base';
import { FAMILIAS, familiaDe, familiasDoCanal } from '../componentes/Rail';
import type { Familia } from '../componentes/Rail';

const DESC_CANAL: Record<string, string> = {
  whatsapp: 'Oficial pela Gupshup, não oficial pela UAZAPI. Cada conta tem quota e segredo próprios.',
  email: 'Envio por API. Campanha fria usa domínio separado do institucional, e a resposta volta pelo inbound.',
  sms: 'Uma linha, 160 caracteres. Confirma intenção e move a conversa de canal.',
  instagram: 'Direct só dentro da janela de 24h aberta pela própria pessoa.',
};

export function Canal() {
  const { canal = 'whatsapp', familia } = useParams<{ canal: string; familia?: Familia }>();
  const nav = useNavigate();
  const { tenant, administra } = useSessao();

  const [provedores, setProvedores] = useState<ProvedorCanal[]>([]);
  const [remetentes, setRemetentes] = useState<Remetente[]>([]);
  const [servidores, setServidores] = useState<Servidor[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState('');

  async function recarregar() {
    try {
      const [p, r, s] = await Promise.all([lerProvedoresCanal(), lerRemetentes(), lerServidores()]);
      setProvedores(p); setRemetentes(r); setServidores(s);
    } catch (e) { setErro(mensagemDeErro(e)); }
    finally { setCarregando(false); }
  }
  useEffect(() => { void recarregar(); }, [tenant?.tenant_id]);

  const doCanal = useMemo(() => provedores.filter((p) => p.canal === canal), [provedores, canal]);
  const familias = familiasDoCanal(doCanal);
  const soIndice = familias.length > 0 && !familia;

  const provs = familia ? doCanal.filter((p) => familiaDe(p) === familia) : doCanal;
  const slugs = new Set(provs.map((p) => p.slug));
  const contas = remetentes.filter((r) => r.canal === canal && slugs.has(r.provedor));

  if (carregando) return <div className="wrap"><p className="vazio">Carregando…</p></div>;

  const quota = contas.reduce((n, r) => n + r.quota_diaria, 0);
  const usado = contas.reduce((n, r) => n + r.enviados_na_janela, 0);

  return (
    <div className="wrap">
      <div className="cabeca"><div>
        <button className="voltar" onClick={() => nav(familia ? `/canais/${canal}` : '/canais')}>
          ← {familia ? NOME_CANAL[canal] : 'Canais'}
        </button>
        <h1>{familia ? `${NOME_CANAL[canal]} · ${FAMILIAS[familia].nome}` : NOME_CANAL[canal]}</h1>
        <p>{familia ? FAMILIAS[familia].desc : DESC_CANAL[canal]}</p>
      </div></div>

      {erro && <Aviso tipo="erro">{erro}</Aviso>}

      <section className="kpis">
        <Kpi rotulo="Contas conectadas" valor={contas.length}
             sub={`${provs.filter((p) => p.tem_adapter).length} provedor(es) com adapter`} />
        <Kpi rotulo="Capacidade diária" valor={quota}
             sub={quota ? `${usado} usada(s) hoje` : 'nenhuma conta ainda'} />
        <Kpi rotulo="Provedores no catálogo" valor={provs.length}
             sub={provs.filter((p) => !p.tem_adapter).length ? 'algum ainda sem adapter' : 'todos com adapter'} />
      </section>

      {soIndice && (
        <>
          <Secao titulo="Como este canal fala" nota="oficial e não oficial têm base contratual e risco diferentes" />
          <section className="indice">
            {familias.map((f) => {
              const s2 = new Set(doCanal.filter((p) => familiaDe(p) === f).map((p) => p.slug));
              const n = remetentes.filter((r) => r.canal === canal && s2.has(r.provedor)).length;
              return (
                <LinhaIndice
                  key={f} icone={canal} cor={corCanal(canal)} titulo={FAMILIAS[f].nome}
                  descricao={`${FAMILIAS[f].desc} · ${doCanal.filter((p) => familiaDe(p) === f).map((p) => p.nome).join(', ')}`}
                  contagem={`${n} conta${n === 1 ? '' : 's'}`}
                  aoClicar={() => nav(`/canais/${canal}/${f}`)}
                />
              );
            })}
          </section>
        </>
      )}

      {!soIndice && (
        <>
          <Secao titulo="Contas conectadas" nota={contas.length ? `${contas.length} no pool` : 'nenhuma ainda'} />
          <section className="indice">
            {contas.length ? contas.map((r) => (
              <LinhaConta key={r.id} conta={r} provedores={provedores}
                          administra={administra} aoMudar={recarregar} />
            )) : (
              <div className="item" style={{ cursor: 'default' }}><span className="txt">
                <b>Nenhuma conta conectada</b>
                <p>Sem conta, o motor adia o passo em vez de prometer envio que não acontece.</p>
              </span></div>
            )}
          </section>

          {familia === 'nao' && (
            <Servidores
              provs={provs} servidores={servidores.filter((s) => slugs.has(s.provedor))}
              remetentes={remetentes} administra={administra} tenant={tenant?.tenant_id ?? ''}
              aoMudar={recarregar}
            />
          )}

          <ConectarConta
            provs={provs} canal={canal} administra={administra}
            tenant={tenant?.tenant_id ?? ''} aoMudar={recarregar}
          />
        </>
      )}
    </div>
  );
}

/** O que cada estado de remetente significa para o pool (D54). */
const ESTADO_CONTA: Record<string, string> = {
  ativo: 'no pool',
  // Quem escreve este é o breaker, e ele volta sozinho quando a janela passa.
  // Por isso a tela o mostra e não o edita: mexer aqui seria discordar do
  // motor sobre um fato que é dele.
  circuito_aberto: 'fora do pool pelo circuito — o breaker devolve sozinho',
  desativado: 'fora do pool à mão',
};

function LinhaConta({ conta, provedores, administra, aoMudar }: {
  conta: Remetente; provedores: ProvedorCanal[];
  administra: boolean; aoMudar(): Promise<void>;
}) {
  const p = provedores.find((x) => x.slug === conta.provedor);
  const pct = conta.quota_diaria ? Math.round((conta.enviados_na_janela / conta.quota_diaria) * 100) : 0;
  const url = `${BASE_FUNCOES}/canal-webhook/${conta.webhook_token}`;
  const [mexendo, setMexendo] = useState(false);
  const [erro, setErro] = useState('');

  const ativo = conta.estado === 'ativo';

  async function alternar() {
    setMexendo(true); setErro('');
    try { await alternarRemetente(conta.id, !ativo); await aoMudar(); }
    catch (e) { setErro(mensagemDeErro(e)); }
    finally { setMexendo(false); }
  }

  return (
    <div className="item" style={{ cursor: 'default', alignItems: 'flex-start' }}>
      <Icone nome={conta.canal} cor={corCanal(conta.canal)} />
      <span className="txt">
        <b style={{ opacity: ativo ? 1 : 0.6 }}>{conta.apelido || conta.identificador}</b>
        <p>
          {p?.nome ?? conta.provedor} · pool {conta.tipo_permitido} ·{' '}
          {conta.enviados_na_janela}/{conta.quota_diaria} hoje ·{' '}
          <b style={{ color: ativo ? 'var(--ok)' : 'var(--warn)' }}>
            {ESTADO_CONTA[conta.estado] ?? conta.estado}
          </b>
          {conta.provider_server_id ? ' · criado pela plataforma' : ''}
        </p>
        <p style={{ marginTop: 6 }}>
          <span style={{ color: 'var(--ink-3)' }}>webhook deste chip: </span>
          <Copiar texto={url} />
        </p>
        {/* Só `ativo` e `desativado` são da tela. `circuito_aberto` é do
            breaker: tirar a conta do circuito à mão seria mandar o motor
            tentar de novo o que ele acabou de ver falhar. */}
        {administra && conta.estado !== 'circuito_aberto' && (
          <p style={{ marginTop: 6 }}>
            <button className="btn" style={{ fontSize: 11, padding: '3px 8px' }}
                    disabled={mexendo} onClick={() => void alternar()}>
              {mexendo ? 'um instante…' : ativo ? 'Tirar do pool' : 'Devolver ao pool'}
            </button>
            <span className="ajuda" style={{ marginLeft: 8 }}>
              Tirar do pool não cancela o que já está na fila: o despacho
              rebalanceia as pendentes para outra conta (D37).
            </span>
          </p>
        )}
        {erro && <p style={{ color: 'var(--crit)', fontSize: 11 }}>{erro}</p>}
      </span>
      <span className={`delta ${pct >= 100 ? 'baixa' : pct > 60 ? 'neutra' : ''}`}>{pct}%</span>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Servidores e criação de instância — só no mundo não oficial (D25, D27)
// ---------------------------------------------------------------------------

function Servidores(props: {
  provs: ProvedorCanal[]; servidores: Servidor[]; remetentes: Remetente[];
  administra: boolean; tenant: string; aoMudar(): Promise<void>;
}) {
  const hospedam = props.provs.filter((p) => p.tem_adapter);
  const [f, setF] = useState({ provedor: '', nome: '', baseUrl: '', adminToken: '' });
  const [estado, setEstado] = useState<'parado' | 'salvando'>('parado');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  const provedor = f.provedor || hospedam[0]?.slug || '';

  async function salvar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null); setEstado('salvando');
    try {
      await salvarServidor({ tenant: props.tenant, provedor, nome: f.nome, baseUrl: f.baseUrl, adminToken: f.adminToken });
      setMsg({ tipo: 'ok', texto: 'Servidor salvo. O token foi para o Vault.' });
      setF({ ...f, adminToken: '' });
      await props.aoMudar();
    } catch (e2) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e2) }); }
    finally { setEstado('parado'); }
  }

  return (
    <>
      <Secao titulo="Servidores de instância"
             nota="a plataforma cria chip novo daqui, sem abrir o painel do provedor" />

      <section className="indice" style={{ marginBottom: 14 }}>
        {props.servidores.length ? props.servidores.map((s) => {
          const p = props.provs.find((x) => x.slug === s.provedor);
          const n = props.remetentes.filter((r) => r.provider_server_id === s.id).length;
          return (
            <div key={s.id} className="item" style={{ cursor: 'default' }}>
              <Icone nome="servidor" />
              <span className="txt">
                <b>{s.nome}</b>
                <p>{p?.nome ?? s.provedor} · <span className="mono">{s.base_url}</span></p>
                <span className="chips" style={{ marginTop: 6 }}>
                  <span className="chip">{n} instância(s)</span>
                  <span className="chip">{s.admin_secret_id ? 'token no Vault' : 'sem token de admin'}</span>
                </span>
              </span>
              <span className={`delta ${s.ativo && s.admin_secret_id ? '' : 'neutra'}`}>
                {s.ativo ? (s.admin_secret_id ? 'pronto' : 'falta token') : 'inativo'}
              </span>
            </div>
          );
        }) : (
          <div className="item" style={{ cursor: 'default' }}><span className="txt">
            <b>Nenhum servidor conectado</b>
            <p>Sem servidor, chip novo tem que ser criado no painel do provedor e cadastrado à mão.</p>
          </span></div>
        )}
      </section>

      {props.administra ? (
        <form className="painel" onSubmit={salvar}>
          <div className="campo">
            <label htmlFor="srv-prov">Provedor</label>
            <select id="srv-prov" value={provedor} onChange={(e) => setF({ ...f, provedor: e.target.value })}>
              {hospedam.map((p) => <option key={p.slug} value={p.slug}>{p.nome}</option>)}
            </select>
          </div>
          <Campo id="srv-nome" rotulo="Nome do servidor" valor={f.nome}
                 aoMudar={(v) => setF({ ...f, nome: v })} placeholder="UAZAPI Afinix"
                 ajuda="Reenviar o mesmo nome edita o servidor em vez de criar outro." />
          <Campo id="srv-url" rotulo="URL" valor={f.baseUrl} mono
                 aoMudar={(v) => setF({ ...f, baseUrl: v })} placeholder="https://suaempresa.uazapi.com"
                 ajuda="Com https://. O banco recusa sem protocolo." />
          <Campo id="srv-admin" rotulo="Token de administração" tipo="senha" valor={f.adminToken}
                 aoMudar={(v) => setF({ ...f, adminToken: v })} obrigatorio={false}
                 vault="Vai direto para o Vault. Em branco na edição, o token guardado fica como está." />
          {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
          <button className="btn prim" disabled={estado === 'salvando' || !f.nome || !f.baseUrl}>
            {estado === 'salvando' ? 'Salvando…' : 'Salvar servidor'}
          </button>
        </form>
      ) : (
        <Aviso tipo="neutro">Só quem administra o cliente configura provedor.</Aviso>
      )}

      <CriarInstancia servidores={props.servidores.filter((s) => s.ativo && s.admin_secret_id)}
                      administra={props.administra} aoMudar={props.aoMudar} />
    </>
  );
}

function CriarInstancia(props: {
  servidores: Servidor[]; administra: boolean; aoMudar(): Promise<void>;
}) {
  const [f, setF] = useState({ serverId: '', apelido: '', identificador: '', tipo: 'fria' as 'morna' | 'fria', quota: '50' });
  const [estado, setEstado] = useState<'parado' | 'criando'>('parado');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);
  const [resultado, setResultado] = useState<{ webhook: string; qr: string | null } | null>(null);

  const serverId = f.serverId || props.servidores[0]?.id || '';

  async function criar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null); setResultado(null); setEstado('criando');
    const r = await provisionarInstancia({
      serverId, apelido: f.apelido, identificador: f.identificador,
      tipo: f.tipo, quota: Number(f.quota) || 1,
    });
    setEstado('parado');
    if (!r.ok) { setMsg({ tipo: 'erro', texto: r.erro ?? 'falha ao criar instância' }); return; }
    setResultado({ webhook: r.webhook_url ?? '', qr: r.qrcode ?? null });
    setMsg({ tipo: 'ok', texto: 'Instância criada. Pareie lendo o QR no WhatsApp do chip.' });
    await props.aoMudar();
  }

  return (
    <>
      <Secao titulo="Criar instância" nota="vira um chip no pool, com quota e webhook próprios" />
      {!props.servidores.length ? (
        <p className="vazio">Conecte um servidor com token de administração antes de criar instância.</p>
      ) : !props.administra ? (
        <Aviso tipo="neutro">Só quem administra o cliente cria instância.</Aviso>
      ) : (
        <form className="painel" onSubmit={criar}>
          <div className="campo">
            <label htmlFor="inst-srv">Servidor</label>
            <select id="inst-srv" value={serverId} onChange={(e) => setF({ ...f, serverId: e.target.value })}>
              {props.servidores.map((s) => <option key={s.id} value={s.id}>{s.nome}</option>)}
            </select>
          </div>
          <Campo id="inst-apelido" rotulo="Apelido do chip" valor={f.apelido}
                 aoMudar={(v) => setF({ ...f, apelido: v })} placeholder="Chip frio SP 02"
                 ajuda="Um número não diz de quem é. O apelido diz." />
          <Campo id="inst-num" rotulo="Número" valor={f.identificador} mono
                 aoMudar={(v) => setF({ ...f, identificador: v })} placeholder="5511988880003" />
          <div className="campo">
            <label htmlFor="inst-pool">Pool</label>
            <select id="inst-pool" value={f.tipo}
                    onChange={(e) => setF({ ...f, tipo: e.target.value as 'morna' | 'fria' })}>
              <option value="fria">fria — lista sem relação prévia</option>
              <option value="morna">morna — base própria com opt-in</option>
            </select>
            <span className="ajuda">Pool frio nunca usa número institucional (D4).</span>
          </div>
          <Campo id="inst-quota" rotulo="Quota diária" valor={f.quota} mono
                 aoMudar={(v) => setF({ ...f, quota: v })} placeholder="50"
                 ajuda="Teto por dia desta conta. O banco recusa passar disso." />

          {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}

          {resultado && (
            <div className="qr">
              {resultado.qr
                ? <img src={resultado.qr.startsWith('data:') ? resultado.qr : `data:image/png;base64,${resultado.qr}`}
                       alt="QR code para parear o WhatsApp" />
                : <p className="vazio">A instância foi criada, mas o QR não veio. Peça de novo pelo painel do provedor.</p>}
              <p style={{ fontSize: 11.5, color: 'var(--ink-3)', textAlign: 'center', margin: 0 }}>
                O QR não fica guardado: ele é credencial de sessão de WhatsApp.
              </p>
              {resultado.webhook && <Copiar texto={resultado.webhook} />}
            </div>
          )}

          <button className="btn prim" disabled={estado === 'criando' || !f.apelido || !f.identificador}>
            {estado === 'criando' ? 'Criando no provedor…' : 'Criar instância'}
          </button>
          <p style={{ fontSize: 11.5, color: 'var(--ink-3)', marginTop: 12 }}>
            O webhook nasce junto: a instância é criada já apontando para o endpoint dela, então a
            resposta do contato não se perde na janela entre criar e apontar.
          </p>
        </form>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
// Conectar conta que já existe no provedor
// ---------------------------------------------------------------------------

function ConectarConta(props: {
  provs: ProvedorCanal[]; canal: string; administra: boolean; tenant: string; aoMudar(): Promise<void>;
}) {
  const [slug, setSlug] = useState('');
  const [valores, setValores] = useState<Record<string, string>>({});
  const [base, setBase] = useState({ apelido: '', identificador: '', tipo: 'morna' as 'morna' | 'fria', quota: '200' });
  const [estado, setEstado] = useState<'parado' | 'salvando'>('parado');
  const [msg, setMsg] = useState<{ tipo: 'erro' | 'ok'; texto: string } | null>(null);

  const p = props.provs.find((x) => x.slug === slug) ?? props.provs[0];

  async function conectar(e: React.FormEvent) {
    e.preventDefault();
    if (!p) return;
    setMsg(null); setEstado('salvando');
    try {
      // A linha primeiro, o segredo logo depois: `salvar_credencial_remetente`
      // precisa de um remetente para saber de qual tenant e provedor é.
      const config = Object.fromEntries(
        p.campos.filter((c) => !c.segredo && valores[c.chave]).map((c) => [c.chave, valores[c.chave]!]),
      );
      const id = await criarRemetente({
        tenant: props.tenant, canal: props.canal, provedor: p.slug,
        identificador: base.identificador, apelido: base.apelido,
        tipo: base.tipo, quota: Number(base.quota) || 1, config,
      });
      const segredos = Object.fromEntries(
        p.campos.filter((c) => valores[c.chave]).map((c) => [c.chave, valores[c.chave]!]),
      );
      await salvarCredencial(id, segredos);
      setMsg({ tipo: 'ok', texto: 'Conta conectada. O segredo foi para o Vault.' });
      setValores({}); setBase({ ...base, apelido: '', identificador: '' });
      await props.aoMudar();
    } catch (e2) { setMsg({ tipo: 'erro', texto: mensagemDeErro(e2) }); }
    finally { setEstado('parado'); }
  }

  if (!p) return null;

  return (
    <>
      <Secao titulo="Conectar outra conta" nota="escolha o provedor e os campos certos aparecem" />
      {!props.administra ? (
        <Aviso tipo="neutro">Só quem administra o cliente conecta conta.</Aviso>
      ) : (
        <form className="painel" onSubmit={conectar}>
          <div className="opts" style={{ marginBottom: 16 }}>
            {props.provs.map((x) => (
              <button key={x.slug} type="button" className="opt" aria-pressed={x.slug === p.slug}
                      onClick={() => { setSlug(x.slug); setValores({}); }}>
                <b>{x.nome}</b><p>{x.descricao}</p>
                {!x.tem_adapter && <span className="chip">sem adapter</span>}
              </button>
            ))}
          </div>

          <Campo id="cc-apelido" rotulo="Apelido da conta" valor={base.apelido}
                 aoMudar={(v) => setBase({ ...base, apelido: v })} placeholder="Comercial SP" />
          <Campo id="cc-num" rotulo="Identificador" valor={base.identificador} mono
                 aoMudar={(v) => setBase({ ...base, identificador: v })}
                 placeholder={props.canal === 'email' ? 'resgate@suaempresa.com.br' : '5511988880001'} />

          {p.campos.map((c) => (
            <Campo
              key={c.chave} id={`cc-${c.chave}`} rotulo={c.rotulo} tipo={c.tipo}
              valor={valores[c.chave] ?? ''} obrigatorio={c.obrigatorio}
              aoMudar={(v) => setValores({ ...valores, [c.chave]: v })}
              ajuda={c.ajuda}
              vault={c.segredo ? 'Vai para o Vault — o banco recusa gravar este campo em config.' : undefined}
            />
          ))}

          <div className="campo">
            <label htmlFor="cc-pool">Pool</label>
            <select id="cc-pool" value={base.tipo}
                    onChange={(e) => setBase({ ...base, tipo: e.target.value as 'morna' | 'fria' })}>
              <option value="morna">morna — base própria com opt-in</option>
              <option value="fria">fria — lista sem relação prévia</option>
            </select>
          </div>
          <Campo id="cc-quota" rotulo="Quota diária" valor={base.quota} mono
                 aoMudar={(v) => setBase({ ...base, quota: v })} placeholder="200" />

          {msg && <Aviso tipo={msg.tipo}>{msg.texto}</Aviso>}
          {!p.tem_adapter && (
            <Aviso tipo="neutro">
              {p.nome} ainda não tem adapter: a conta é cadastrada, mas não envia.
            </Aviso>
          )}
          <button className="btn prim" disabled={estado === 'salvando' || !base.identificador}>
            {estado === 'salvando' ? 'Conectando…' : 'Conectar conta'}
          </button>
        </form>
      )}
    </>
  );
}
