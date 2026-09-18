import { useEffect, useState } from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { ProvedorSessao, useSessao } from './sessao';
import { Rail } from './componentes/Rail';
import { Aviso, Campo } from './componentes/base';
import { Entrar } from './telas/Entrar';
import { Canal } from './telas/Canal';
import {
  Canais, Config, ConfigAgentes, ConfigIA, ConfigModelos, ConfigPlataformas, Hub,
} from './telas/Telas';
import { lerProvedoresCanal, criarTenant } from './dados';
import type { ProvedorCanal } from './dados';
import { mensagemDeErro } from './supabase';

export function App() {
  return (
    <ProvedorSessao>
      <BrowserRouter>
        <Portao />
      </BrowserRouter>
    </ProvedorSessao>
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
