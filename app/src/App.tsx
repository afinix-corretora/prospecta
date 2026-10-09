import { useEffect, useState } from 'react';
import { BrowserRouter, Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { ProvedorSessao, useSessao } from './sessao';
import { Rail, iniciais } from './componentes/Rail';
import { Ico, Marca } from './componentes/icones';
import { useTema } from './componentes/tema';
import { Aviso, Campo } from './componentes/base';
import { DefinirSenha, Entrar } from './telas/Entrar';
import { Canal } from './telas/Canal';
import { ConfigEmail } from './telas/ConfigEmail';
import { ConfigBlacklist } from './telas/ConfigBlacklist';
import { ConfigCRM } from './telas/ConfigCRM';
import { Importar } from './telas/Importar';
import { Contatos } from './telas/Contatos';
import { Campanha } from './telas/Campanha';
import { Cadencia, Cadencias } from './telas/Cadencias';
import { Funil } from './telas/Funil';
import { Respostas } from './telas/Respostas';
import { Supressao } from './telas/Supressao';
import { Writeback } from './telas/Writeback';
import { Setup } from './telas/Inicio';
import { Painel } from './telas/Painel';
import {
  Canais, Config, ConfigAgentes, ConfigIA, ConfigModelos, ConfigPlataformas,
  ConfigVinculadas, Hub,
} from './telas/Telas';
import { lerProvedoresCanal, lerRespostas, criarTenant } from './dados';
import type { ProvedorCanal } from './dados';
import { configurado, faltando, mensagemDeErro } from './supabase';
import { carimboLegivel } from './carimbo';

export function App() {
  // Antes de qualquer coisa: sem configuração não há o que tentar, e dizer o
  // que falta vale mais do que uma tela em branco.
  if (!configurado) return <SemConfiguracao />;

  return (
    <ProvedorSessao>
      <BrowserRouter>
        <Portao />
      </BrowserRouter>
    </ProvedorSessao>
  );
}

function SemConfiguracao() {
  return (
    <div className="entrar">
      <div style={{ width: 'min(520px, 100%)' }} className="painel">
        <h1 style={{ fontSize: 22 }}>Falta configurar</h1>
        <p style={{ color: 'var(--ink-2)' }}>
          {faltando.length === 1 ? 'A variável' : 'As variáveis'}{' '}
          {faltando.map((f) => <code key={f} className="mono">{f}</code>)
            .reduce((a, b) => <>{a} e {b}</>)}{' '}
          {faltando.length === 1 ? 'não chegou' : 'não chegaram'} ao navegador.
        </p>
        <Aviso tipo="neutro">
          <b>Na Vercel:</b> Settings → Environment Variables, nos três ambientes.
          Variável adicionada não entra num deploy que já passou — é preciso
          <b> redeploy</b>.<br /><br />
          <b>Local:</b> copie <code className="mono">app/.env.example</code> para{' '}
          <code className="mono">app/.env.local</code> e reinicie o
          <code className="mono"> npm run dev</code>.
        </Aviso>

        {/* O carimbo separa as duas causas que produzem esta mesma tela: a
            variável não foi salva, ou o build é anterior a ela. Sem ele a
            pessoa salva de novo, recarrega, vê isto igual, e conclui que o
            app está quebrado. */}
        <p style={{ fontSize: 12, color: 'var(--ink-3)' }}>
          Este build: <code className="mono">{carimboLegivel()}</code>.<br />
          Se esse horário é <b>anterior</b> ao momento em que você salvou a
          variável, quem está velho é o build — Deployments → ⋯ →{' '}
          <b>Redeploy</b>, sem cache. O horário não muda? O deploy não saiu
          desta branch.
        </p>
        <p style={{ fontSize: 12, color: 'var(--ink-3)', marginBottom: 0 }}>
          O prefixo <code className="mono">VITE_</code> é obrigatório: o Vite só
          expõe ao navegador variável que o tenha.
        </p>
      </div>
    </div>
  );
}

function Portao() {
  const { sessao, carregando, tenant, tenants, definindoSenha } = useSessao();

  if (carregando) return <div className="entrar"><p className="vazio">Carregando…</p></div>;
  if (!sessao) return <Entrar />;
  // Chegou pelo e-mail de "definir senha": a sessão existe, mas o painel
  // espera a senha nova — senão o link vira acesso sem troca de senha (D60).
  if (definindoSenha) return <DefinirSenha />;
  // Logado e sem cliente nenhum: é o primeiro acesso, e criar o próprio é a
  // única coisa que dá para fazer. `criar_tenant` põe quem chamou como dono.
  if (!tenants.length) return <PrimeiroCliente />;
  if (!tenant) return <div className="entrar"><p className="vazio">Carregando cliente…</p></div>;

  return <Casca />;
}

function Casca() {
  const { tenant, sessao } = useSessao();
  const { pathname } = useLocation();
  const [provedores, setProvedores] = useState<ProvedorCanal[]>([]);
  const [respostasHoje, setRespostasHoje] = useState(0);
  const [gaveta, setGaveta] = useState(false);
  const [tema, alternarTema] = useTema();

  useEffect(() => { lerProvedoresCanal().then(setProvedores).catch(() => setProvedores([])); }, []);

  // O número ao lado de "Respostas" no menu. Lido a cada troca de tela, que
  // é quando a pessoa está olhando para o menu; erro aqui não derruba nada.
  useEffect(() => {
    if (!tenant) return;
    const desde = Date.now() - 24 * 3600 * 1000;
    lerRespostas(tenant.tenant_id, undefined, 100)
      .then((rs) => setRespostasHoje(rs.filter((r) => Date.parse(r.ocorrido_em) >= desde).length))
      .catch(() => setRespostasHoje(0));
  }, [tenant, pathname]);

  // Mudou de tela no celular: a gaveta fecha sozinha.
  useEffect(() => { setGaveta(false); }, [pathname]);

  return (
    <div className="shell" data-gaveta={gaveta}>
      <Rail provedores={provedores} respostasHoje={respostasHoje} tema={tema} aoTrocarTema={alternarTema} />
      <div className="veu" onClick={() => setGaveta(false)} aria-hidden="true" />
      <main>
        <Topo aoAbrirMenu={() => setGaveta(true)} nomeCliente={tenant?.nome ?? ''}
              papel={tenant?.papel ?? ''} email={sessao?.user.email ?? ''}
              tema={tema} aoTrocarTema={alternarTema} />
        <Routes>
          {/* O painel é a porta de entrada: o que rendeu, quem respondeu, o que
              pede ação. O Setup rápido (D72) mora em /setup e aparece no
              painel como cartão de progresso enquanto houver passo pendente. */}
          <Route path="/" element={<Painel />} />
          <Route path="/setup" element={<Setup />} />
          <Route path="/configurar" element={<Navigate to="/setup" replace />} />
          <Route path="/campanhas" element={<Hub />} />
          <Route path="/campanhas/:id" element={<Campanha />} />
          <Route path="/cadencias" element={<Cadencias />} />
          <Route path="/cadencias/:id" element={<Cadencia />} />
          <Route path="/contatos" element={<Contatos />} />
          <Route path="/respostas" element={<Respostas />} />
          <Route path="/funil" element={<Funil />} />
          <Route path="/supressao" element={<Supressao />} />
          <Route path="/writeback" element={<Writeback />} />
          <Route path="/contatos/importar" element={<Importar />} />
          <Route path="/canais" element={<Canais />} />
          {/* E-mail mora em Configurações (D62): a mesma conta em duas telas
              seria duas versões do mesmo fato. */}
          <Route path="/canais/email" element={<Navigate to="/config/email" replace />} />
          <Route path="/canais/:canal" element={<Canal />} />
          <Route path="/canais/:canal/:familia" element={<Canal />} />
          <Route path="/config" element={<Config />} />
          <Route path="/config/email" element={<ConfigEmail />} />
          <Route path="/config/blacklist" element={<ConfigBlacklist />} />
          <Route path="/config/ia" element={<ConfigIA />} />
          <Route path="/config/agentes" element={<ConfigAgentes />} />
          <Route path="/config/modelos" element={<ConfigModelos />} />
          <Route path="/config/plataformas" element={<ConfigPlataformas />} />
          <Route path="/config/vinculadas" element={<ConfigVinculadas />} />
          <Route path="/config/vinculadas/:id" element={<ConfigCRM />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  );
}

/** A barra do topo: buscar contato de qualquer tela, trocar o tema, e saber
 *  em qual cliente se está. No celular, abre o menu. */
function Topo(props: {
  aoAbrirMenu(): void; nomeCliente: string; papel: string; email: string;
  tema: 'dark' | 'light'; aoTrocarTema(): void;
}) {
  const nav = useNavigate();
  const [termo, setTermo] = useState('');
  return (
    <header className="topo">
      <button className="icobtn menu" onClick={props.aoAbrirMenu} aria-label="Abrir menu">
        <Ico nome="menu" />
      </button>
      <span className="marca-topo"><Marca />Prospecta</span>
      <form role="search" onSubmit={(e) => {
        e.preventDefault();
        nav(`/contatos?busca=${encodeURIComponent(termo.trim())}`);
      }}>
        <Ico nome="busca" />
        <input type="search" value={termo} onChange={(e) => setTermo(e.target.value)}
               placeholder="Buscar contato por nome ou número" aria-label="Buscar contato" />
      </form>
      <div className="dir">
        {/* D72: o atalho para conectar canal, IA e CRM fica à vista em toda tela. */}
        <button className="btn mini prim setup-rapido" onClick={() => nav('/setup')}>
          <Ico nome="raio" /><span>Setup rápido</span>
        </button>
        <button className="icobtn" onClick={props.aoTrocarTema}
                aria-label={props.tema === 'dark' ? 'Usar tema claro' : 'Usar tema escuro'}
                title={props.tema === 'dark' ? 'Tema claro' : 'Tema escuro'}>
          <Ico nome={props.tema === 'dark' ? 'sol' : 'lua'} />
        </button>
        {/* Só o avatar: o nome do cliente já está no menu e na saudação. */}
        <span className="cliente avatar" title={`${props.nomeCliente} · ${props.papel} · ${props.email}`}
              aria-label={`${props.nomeCliente}, ${props.papel}`}>{iniciais(props.nomeCliente)}</span>
      </div>
    </header>
  );
}

function PrimeiroCliente() {
  const { recarregarTenants } = useSessao();
  const [nome, setNome] = useState('');
  const [slug, setSlug] = useState('');
  const [erro, setErro] = useState('');
  const [estado, setEstado] = useState<'parado' | 'criando'>('parado');

  async function criar(e: React.FormEvent) {
    e.preventDefault();
    setErro(''); setEstado('criando');
    try { await criarTenant(nome, slug); await recarregarTenants(); }
    catch (e2) { setErro(mensagemDeErro(e2)); setEstado('parado'); }
  }

  return (
    <div className="entrar">
      <form onSubmit={criar}>
        <div className="selo"><Marca /><b>Prospecta</b></div>
        <h1>Seu cliente</h1>
        <p>Você ainda não pertence a nenhum. Criar um põe você como dono dele.</p>
        <Campo id="t-nome" rotulo="Nome" valor={nome}
               aoMudar={(v) => {
                 setNome(v);
                 setSlug(v.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
                          .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40));
               }}
               placeholder="Afinix Corretora" />
        <Campo id="t-slug" rotulo="Identificador" valor={slug} aoMudar={setSlug} mono
               ajuda="Minúsculas, números e hífen. É o que aparece em URL." />
        {erro && <Aviso tipo="erro">{erro}</Aviso>}
        <button className="btn prim" disabled={estado === 'criando' || !nome || slug.length < 3}>
          {estado === 'criando' ? 'Criando…' : 'Criar cliente'}
        </button>
      </form>
    </div>
  );
}
