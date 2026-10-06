import { useLocation, useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { NOME_CANAL } from './base';
import { Ico, Marca } from './icones';
import { sb } from '../supabase';
import type { ProvedorCanal } from '../dados';

const Chevron = () => (
  <svg className="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor"
       strokeWidth="2" strokeLinecap="round"><path d="M9 6l6 6-6 6" /></svg>
);

export const FAMILIAS = {
  oficial: {
    nome: 'API Oficial',
    desc: 'Número homologado pela plataforma. Base própria com opt-in, volume alto.',
  },
  nao: {
    nome: 'API não oficial',
    desc: 'Automação de chip. Campanha fria, volume baixo, longe do institucional (D4).',
  },
} as const;

export type Familia = keyof typeof FAMILIAS;

export const familiaDe = (p: ProvedorCanal): Familia => (p.oficial ? 'oficial' : 'nao');

/** Canal só vira grupo quando tem mesmo os dois mundos — sem submenu vazio. */
export function familiasDoCanal(provs: ProvedorCanal[]): Familia[] {
  const f = [...new Set(provs.map(familiaDe))];
  return f.length > 1 ? (['oficial', 'nao'] as Familia[]).filter((x) => f.includes(x)) : [];
}

/** Iniciais para o avatar: "Afinix Corretora" → "AC". */
export function iniciais(texto: string | null | undefined): string {
  const partes = (texto ?? '').trim().split(/\s+/).filter(Boolean);
  return ((partes[0]?.[0] ?? '') + (partes[1]?.[0] ?? '')).toUpperCase() || '·';
}

export function Rail({ provedores, respostasHoje, tema, aoTrocarTema }: {
  provedores: ProvedorCanal[];
  /** Respostas das últimas 24h: o número que faz alguém abrir a caixa. */
  respostasHoje: number;
  tema: 'dark' | 'light';
  aoTrocarTema(): void;
}) {
  const nav = useNavigate();
  const { pathname } = useLocation();
  const { tenant, tenants, trocarTenant, sessao } = useSessao();

  const canais = ['whatsapp', 'email', 'sms', 'instagram'].filter(
    (c) => provedores.some((p) => p.canal === c),
  );

  const emCanais = pathname.startsWith('/canais');
  const emConfig = pathname.startsWith('/config');
  const atual = (rota: string) => pathname === rota;

  const Item = ({ rota, icone, rotulo, ativo, conta }: {
    rota: string; icone: string; rotulo: string; ativo?: boolean; conta?: number;
  }) => (
    <button aria-current={ativo ?? atual(rota)} onClick={() => nav(rota)}>
      <Ico nome={icone} /><span>{rotulo}</span>
      {conta ? <span className="conta" aria-label={`${conta} nas últimas 24 horas`}>{conta > 99 ? '99+' : conta}</span> : null}
    </button>
  );

  return (
    <aside className="rail" aria-label="Navegação">
      <button className="brand" onClick={() => nav('/')} aria-label="Prospecta — início">
        <Marca /><span><b>Prospecta</b><span>Motor de cadência</span></span>
      </button>

      {/* A operação do dia primeiro: o que voltou, onde cada lead está, o que
          está rodando. A base e a saída para o CRM logo abaixo. */}
      <nav className="nav">
        <Item rota="/" icone="inicio" rotulo="Início" />
        <Item rota="/respostas" icone="respostas" rotulo="Respostas" conta={respostasHoje} />
        <Item rota="/funil" icone="funil" rotulo="Funil" />
        <Item rota="/campanhas" icone="campanhas" rotulo="Campanhas"
              ativo={atual('/campanhas') || pathname.startsWith('/campanhas/')} />
        <Item rota="/cadencias" icone="cadencias" rotulo="Cadências" ativo={pathname.startsWith('/cadencias')} />
        <Item rota="/contatos" icone="contatos" rotulo="Contatos" />
        <Item rota="/contatos/importar" icone="importar" rotulo="Importar" />
        <Item rota="/supressao" icone="supressao" rotulo="Supressão" />
        <Item rota="/writeback" icone="writeback" rotulo="Writeback" />
      </nav>

      {/* Grupos fechados por padrão: abrem índice, não conteúdo (D21). */}
      <nav className="nav" aria-label="Integrações e configurações">
        <button
          className="grupo"
          aria-current={atual('/canais')}
          aria-expanded={emCanais}
          onClick={() => (emCanais && atual('/canais') ? nav('/') : nav('/canais'))}
        >
          <Ico nome="canais" /><span>Canais</span><Chevron />
        </button>
        <div className="sub" data-aberto={emCanais}>
          <div>
            {canais.map((c) => {
              const provs = provedores.filter((p) => p.canal === c);
              const familias = familiasDoCanal(provs);
              if (!familias.length) {
                return (
                  <button key={c} aria-current={atual(`/canais/${c}`)} onClick={() => nav(`/canais/${c}`)}>
                    {NOME_CANAL[c]}
                  </button>
                );
              }
              const aberto = pathname.startsWith(`/canais/${c}`);
              return (
                <div key={c}>
                  <button
                    className="grupo2"
                    aria-current={atual(`/canais/${c}`)}
                    aria-expanded={aberto}
                    onClick={() => nav(`/canais/${c}`)}
                  >
                    <span>{NOME_CANAL[c]}</span><Chevron />
                  </button>
                  <div className="sub2" data-aberto={aberto}>
                    <div>
                      {familias.map((f) => (
                        <button
                          key={f}
                          aria-current={atual(`/canais/${c}/${f}`)}
                          onClick={() => nav(`/canais/${c}/${f}`)}
                        >
                          {FAMILIAS[f].nome}
                        </button>
                      ))}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        <button
          className="grupo"
          aria-current={atual('/config')}
          aria-expanded={emConfig || atual('/configurar')}
          onClick={() => (emConfig && atual('/config') ? nav('/') : nav('/config'))}
        >
          <Ico nome="config" /><span>Configurações</span><Chevron />
        </button>
        <div className="sub" data-aberto={emConfig || atual('/configurar')}>
          <div>
            <button aria-current={atual('/configurar')} onClick={() => nav('/configurar')}>Assistente</button>
            <button aria-current={atual('/config/email')} onClick={() => nav('/config/email')}>E-mail</button>
            <button aria-current={atual('/config/blacklist')} onClick={() => nav('/config/blacklist')}>Blacklist</button>
            <button aria-current={atual('/config/ia')} onClick={() => nav('/config/ia')}>Provedores de IA</button>
            <button aria-current={atual('/config/agentes')} onClick={() => nav('/config/agentes')}>Agentes</button>
            <button aria-current={atual('/config/modelos')} onClick={() => nav('/config/modelos')}>Modelos de conversa</button>
            <button aria-current={atual('/config/plataformas')} onClick={() => nav('/config/plataformas')}>Plataformas de contato</button>
            <button aria-current={atual('/config/vinculadas')} onClick={() => nav('/config/vinculadas')}>Plataformas vinculadas</button>
          </div>
        </div>
      </nav>

      <div className="railfoot">
        {tenants.length > 1 ? (
          <div className="campo">
            <label htmlFor="tenant">Cliente</label>
            <select id="tenant" value={tenant?.tenant_id ?? ''} onChange={(e) => trocarTenant(e.target.value)}>
              {tenants.map((t) => <option key={t.tenant_id} value={t.tenant_id}>{t.nome}</option>)}
            </select>
          </div>
        ) : (
          <div className="quem">
            <span className="avatar" aria-hidden="true">{iniciais(tenant?.nome)}</span>
            <div><b>{tenant?.nome ?? '—'}</b><small>{sessao?.user.email ?? ''}</small></div>
          </div>
        )}
        <div className="acoes-rail">
          <button onClick={aoTrocarTema} aria-label={tema === 'dark' ? 'Usar tema claro' : 'Usar tema escuro'}>
            <Ico nome={tema === 'dark' ? 'sol' : 'lua'} />{tema === 'dark' ? 'Claro' : 'Escuro'}
          </button>
          <button onClick={() => void sb.auth.signOut()}><Ico nome="sair" />Sair</button>
        </div>
      </div>
    </aside>
  );
}
