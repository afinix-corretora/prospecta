import { useEffect, useState } from 'react';
import { Ico } from './icones';
import type { CSSProperties, ReactNode } from 'react';

export const IC: Record<string, ReactNode> = {
  whatsapp: <path d="M4 20l1.3-4A8 8 0 1 1 8 18.7z" />,
  email: <><rect x="3" y="5.5" width="18" height="13" rx="2.5" /><path d="M4 7l8 6 8-6" /></>,
  sms: <path d="M4.5 5.5h15v10h-9l-4 3.5v-3.5h-2z" />,
  instagram: <><rect x="3.5" y="3.5" width="17" height="17" rx="5" /><circle cx="12" cy="12" r="3.8" /><circle cx="17" cy="7" r="1.1" /></>,
  ia: <><path d="M12 3v3m0 12v3m9-9h-3M6 12H3m14.5-6.5l-2 2m-7 7l-2 2m0-11l2 2m7 7l2 2" /><circle cx="12" cy="12" r="3.5" /></>,
  agente: <><circle cx="12" cy="8" r="3.5" /><path d="M4.5 20a7.5 7.5 0 0 1 15 0" /></>,
  modelo: <><rect x="3.5" y="4.5" width="17" height="15" rx="2.5" /><path d="M8 9.5h8M8 14h5" /></>,
  plataforma: <><rect x="3.5" y="4.5" width="17" height="12" rx="2.5" /><path d="M8 20h8M12 16.5V20" /></>,
  bloqueio: <><circle cx="12" cy="12" r="8.5" /><path d="M6 6l12 12" /></>,
  servidor: <><rect x="3.5" y="4" width="17" height="6.5" rx="2" /><rect x="3.5" y="13.5" width="17" height="6.5" rx="2" /><path d="M7 7.25h.01M7 16.75h.01" /></>,
  campanha: <><path d="M4 10v4a1 1 0 0 0 1 1h3l6 4V5L8 9H5a1 1 0 0 0-1 1z" /><path d="M17.5 9a4 4 0 0 1 0 6" /></>,
};

/** Fundo do ícone na cor do canal, mas diluída, e o ícone (ou as iniciais)
 *  na cor do canal puxada para a tinta do texto. A cor pura sobre a própria
 *  diluição não passa de 4,5:1 no tema claro — conferido —, e puxar para
 *  `--ink` resolve nos dois temas sem uma segunda tabela de cores. */
export function tinta(cor: string): CSSProperties {
  return {
    background: `color-mix(in oklab, ${cor} 16%, transparent)`,
    color: `color-mix(in oklab, ${cor} 72%, var(--ink))`,
  };
}

export function Icone({ nome, cor }: { nome: string; cor?: string }) {
  return (
    <span className="ico" style={cor ? tinta(cor) : undefined}>
      <svg viewBox="0 0 24 24" strokeLinejoin="round" strokeLinecap="round">{IC[nome] ?? IC.plataforma}</svg>
    </span>
  );
}

export const Seta = () => (
  <svg className="seta" viewBox="0 0 24 24" strokeLinecap="round"><path d="M9 6l6 6-6 6" /></svg>
);

export function corCanal(id: string): string {
  return ({ whatsapp: 'var(--wa)', email: 'var(--mail)', sms: 'var(--sms)', instagram: 'var(--ig)' } as Record<string, string>)[id]
    ?? 'var(--ink-3)';
}

export const NOME_CANAL: Record<string, string> = {
  whatsapp: 'WhatsApp', email: 'E-mail', sms: 'SMS', instagram: 'Instagram',
};

export function LinhaIndice(props: {
  icone: string; cor?: string; titulo: string; descricao: string;
  contagem?: ReactNode; aoClicar?: () => void;
}) {
  const conteudo = (
    <>
      <Icone nome={props.icone} cor={props.cor} />
      <span className="txt"><b>{props.titulo}</b><p>{props.descricao}</p></span>
      {props.contagem != null && <span className="cont">{props.contagem}</span>}
      {/* Sem clique, o lugar da seta fica: a coluna da direita não pula. */}
      {props.aoClicar ? <Seta /> : <span className="seta" aria-hidden="true" />}
    </>
  );
  return props.aoClicar
    ? <button className="item" onClick={props.aoClicar}>{conteudo}</button>
    : <div className="item" style={{ cursor: 'default' }}>{conteudo}</div>;
}

export function Kpi({ rotulo, valor, sub }: { rotulo: string; valor: ReactNode; sub: string }) {
  return (
    <div className="kpi">
      <span className="r">{rotulo}</span>
      <b className="mono">{valor}</b>
      <span className="s">{sub}</span>
    </div>
  );
}

export function Campo(props: {
  id: string; rotulo: string; valor: string; aoMudar(v: string): void;
  tipo?: 'texto' | 'senha' | 'email'; obrigatorio?: boolean; ajuda?: string | null;
  vault?: string; placeholder?: string; mono?: boolean;
  /** `autocomplete` do input — sem ele o gerenciador de senhas não preenche o login. */
  autocompletar?: string;
}) {
  return (
    <div className="campo">
      <label htmlFor={props.id}>
        {props.rotulo}
        {props.obrigatorio === false && <span style={{ color: 'var(--ink-3)', fontWeight: 400 }}> (opcional)</span>}
      </label>
      <input
        id={props.id}
        className={props.mono ? 'mono' : undefined}
        type={props.tipo === 'senha' ? 'password' : props.tipo === 'email' ? 'email' : 'text'}
        autoComplete={props.autocompletar}
        value={props.valor}
        placeholder={props.placeholder ?? (props.tipo === 'senha' ? '••••••••••••' : '')}
        onChange={(e) => props.aoMudar(e.target.value)}
      />
      {props.ajuda && <span className="ajuda">{props.ajuda}</span>}
      {props.vault && <span className="vault">{props.vault}</span>}
    </div>
  );
}

/** Copiar a URL do webhook é a ação mais repetida de quem conecta chip. */
export function Copiar({ texto }: { texto: string }) {
  const [copiado, setCopiado] = useState(false);
  useEffect(() => {
    if (!copiado) return;
    const t = setTimeout(() => setCopiado(false), 1200);
    return () => clearTimeout(t);
  }, [copiado]);
  return (
    <button
      className={`copiar mono${copiado ? ' ok' : ''}`}
      title="copiar"
      onClick={async () => {
        // Sem permissão de clipboard o texto continua à vista para selecionar.
        try { await navigator.clipboard.writeText(texto); } catch { /* ignora */ }
        setCopiado(true);
      }}
    >
      {copiado ? 'copiado' : texto}
    </button>
  );
}

export function Aviso({ tipo, children }: { tipo: 'erro' | 'ok' | 'neutro'; children: ReactNode }) {
  return <div className={`aviso ${tipo}`}>{children}</div>;
}

export function Secao({ titulo, nota }: { titulo: string; nota?: ReactNode }) {
  return <div className="sec"><h2>{titulo}</h2>{nota && <span>{nota}</span>}</div>;
}

/**
 * A moldura de toda tela: a margem da página, o título como h1, a frase que
 * diz para que a tela serve e, quando há, o caminho de volta e a ação
 * principal. Tela que começava com uma `Secao` no lugar do título encostava
 * no menu e não tinha cabeçalho — é o que esta peça impede.
 */
export function Pagina({ titulo, sub, voltar, acao, larga, children }: {
  titulo: ReactNode;
  /** Quadro, tabela ou painel: usa a largura toda. O resto (formulário,
   *  lista de configuração, leitura) fica numa coluna que o olho percorre. */
  larga?: boolean;
  sub?: ReactNode;
  voltar?: { rotulo: string; aoClicar(): void };
  acao?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div className={larga ? 'wrap larga' : 'wrap'}>
      <div className="cabeca">
        <div>
          {voltar && (
            <button className="voltar" onClick={voltar.aoClicar}><Ico nome="voltar" className="" />{voltar.rotulo}</button>
          )}
          <h1>{titulo}</h1>
          {sub && <p>{sub}</p>}
        </div>
        {acao && <div className="cta">{acao}</div>}
      </div>
      {children}
    </div>
  );
}
