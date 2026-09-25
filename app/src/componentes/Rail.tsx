import { useLocation, useNavigate } from 'react-router-dom';
import { useSessao } from '../sessao';
import { NOME_CANAL } from './base';
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

export function Rail({ provedores }: { provedores: ProvedorCanal[] }) {
  const nav = useNavigate();
  const { pathname } = useLocation();
  const { tenant, tenants, trocarTenant, sessao } = useSessao();

  const canais = ['whatsapp', 'email', 'sms', 'instagram'].filter(
    (c) => provedores.some((p) => p.canal === c),
  );

  const emCanais = pathname.startsWith('/canais');
  const emConfig = pathname.startsWith('/config');
  const atual = (rota: string) => pathname === rota;

  return (
    <aside className="rail">
      <div className="brand"><b>Prospecta</b><span>Motor de cadência</span></div>

      <nav className="nav">
        <button aria-current={atual('/')} onClick={() => nav('/')}>Campanhas</button>

        {/* Primeiro nível, ao lado das campanhas: é a outra metade da mesma
            pergunta. A campanha diz PARA QUEM e por quais canais; a cadência
            diz O QUE se manda e quando. */}
        <button aria-current={pathname.startsWith('/cadencias')}
                onClick={() => nav('/cadencias')}>
          Cadências
        </button>

        {/* Entrada de contato. Primeiro nível porque é o primeiro quadro do
            diagrama: sem ela o motor não tem sobre o que rodar. */}
        <button aria-current={atual('/contatos')} onClick={() => nav('/contatos')}>
          Contatos
        </button>
        <button
          aria-current={atual('/contatos/importar')}
          onClick={() => nav('/contatos/importar')}
        >
          Importar
        </button>
        {/* Primeiro nível junto dos contatos: é a outra metade da base — quem
            está dentro e quem nunca pode ser tocado. */}
        <button aria-current={atual('/supressao')} onClick={() => nav('/supressao')}>
          Supressão
        </button>

        {/* A seta que volta. O texto da resposta era gravado e ilegível —
            pessoa interessada esperando resposta que ninguém sabia que
            existia. Primeiro nível porque é a pergunta mais urgente do dia. */}
        <button aria-current={atual('/respostas')} onClick={() => nav('/respostas')}>
          Respostas
        </button>

        {/* Onde cada lead está. Primeiro nível porque é a pergunta que o dono
            da operação faz primeiro — e a que o produto não sabia responder. */}
        <button aria-current={atual('/funil')} onClick={() => nav('/funil')}>
          Funil
        </button>

        {/* A última seta do diagrama, e a única que sai do motor para fora.
            Primeiro nível porque a pergunta que ela responde — "o CRM já sabe?"
            — é operacional diária, não configuração. */}
        <button aria-current={atual('/writeback')} onClick={() => nav('/writeback')}>
          Writeback
        </button>

        <button
          className="grupo"
          aria-current={atual('/canais')}
          aria-expanded={emCanais}
          onClick={() => (emCanais && atual('/canais') ? nav('/') : nav('/canais'))}
        >
          <span>Canais</span><Chevron />
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
          aria-expanded={emConfig}
          onClick={() => (emConfig && atual('/config') ? nav('/') : nav('/config'))}
        >
          <span>Configurações</span><Chevron />
        </button>
        <div className="sub" data-aberto={emConfig}>
          <div>
            <button aria-current={atual('/config/ia')} onClick={() => nav('/config/ia')}>Provedores de IA</button>
            <button aria-current={atual('/config/agentes')} onClick={() => nav('/config/agentes')}>Agentes</button>
            <button aria-current={atual('/config/modelos')} onClick={() => nav('/config/modelos')}>Modelos de conversa</button>
            <button aria-current={atual('/config/plataformas')} onClick={() => nav('/config/plataformas')}>Plataformas de contato</button>
          </div>
        </div>
      </nav>

      <div className="railfoot">
        {tenants.length > 1 ? (
          <div className="campo" style={{ margin: 0 }}>
            <label htmlFor="tenant">Cliente</label>
            <select id="tenant" value={tenant?.tenant_id ?? ''} onChange={(e) => trocarTenant(e.target.value)}>
              {tenants.map((t) => <option key={t.tenant_id} value={t.tenant_id}>{t.nome}</option>)}
            </select>
          </div>
        ) : (
          <div><b>{tenant?.nome ?? '—'}</b><br />{tenant?.papel ?? ''}</div>
        )}
        <div>{sessao?.user.email}</div>
        <button onClick={() => void sb.auth.signOut()}>Sair</button>
      </div>
    </aside>
  );
}
