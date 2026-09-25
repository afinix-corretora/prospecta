import { useEffect, useState } from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { ProvedorSessao, useSessao } from './sessao';
import { Rail } from './componentes/Rail';
import { Aviso, Campo } from './componentes/base';
import { Entrar } from './telas/Entrar';
import { Canal } from './telas/Canal';
import { Importar } from './telas/Importar';
import { Contatos } from './telas/Contatos';
import { Campanha } from './telas/Campanha';
import { Cadencia, Cadencias } from './telas/Cadencias';
import { Funil } from './telas/Funil';
import { Respostas } from './telas/Respostas';
import { Supressao } from './telas/Supressao';
import { Writeback } from './telas/Writeback';
import {
  Canais, Config, ConfigAgentes, ConfigIA, ConfigModelos, ConfigPlataformas, Hub,
} from './telas/Telas';
import { lerProvedoresCanal, criarTenant } from './dados';
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
  const { sessao, carregando, tenant, tenants } = useSessao();

  if (carregando) return <div className="entrar"><p className="vazio">Carregando…</p></div>;
  if (!sessao) return <Entrar />;
  // Logado e sem cliente nenhum: é o primeiro acesso, e criar o próprio é a
  // única coisa que dá para fazer. `criar_tenant` põe quem chamou como dono.
  if (!tenants.length) return <PrimeiroCliente />;
  if (!tenant) return <div className="entrar"><p className="vazio">Carregando cliente…</p></div>;

  return <Casca />;
}

function Casca() {
  const [provedores, setProvedores] = useState<ProvedorCanal[]>([]);
  useEffect(() => { lerProvedoresCanal().then(setProvedores).catch(() => setProvedores([])); }, []);

  return (
    <div className="shell">
      <Rail provedores={provedores} />
      <main>
        <Routes>
          <Route path="/" element={<Hub />} />
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
          <Route path="/canais/:canal" element={<Canal />} />
          <Route path="/canais/:canal/:familia" element={<Canal />} />
          <Route path="/config" element={<Config />} />
          <Route path="/config/ia" element={<ConfigIA />} />
          <Route path="/config/agentes" element={<ConfigAgentes />} />
          <Route path="/config/modelos" element={<ConfigModelos />} />
          <Route path="/config/plataformas" element={<ConfigPlataformas />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
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
