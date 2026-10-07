/**
 * Ícones do produto: desenhados aqui, num traço só (1.7, cantos redondos, grade
 * de 24), para o menu, o topo e o painel falarem a mesma língua. Nada de emoji
 * nem de glifo de fonte no lugar de ícone.
 */
import type { ReactNode } from 'react';

const P: Record<string, ReactNode> = {
  inicio: <><rect x="3.5" y="3.5" width="7" height="8" rx="2" /><rect x="13.5" y="3.5" width="7" height="5" rx="2" /><rect x="13.5" y="11.5" width="7" height="9" rx="2" /><rect x="3.5" y="14.5" width="7" height="6" rx="2" /></>,
  respostas: <><path d="M4 18.5V7a3 3 0 0 1 3-3h10a3 3 0 0 1 3 3v6.5a3 3 0 0 1-3 3H8z" /><path d="M8.5 9h7M8.5 12.5h4.5" /></>,
  funil: <><rect x="3.5" y="4" width="4.5" height="16" rx="1.8" /><rect x="9.75" y="4" width="4.5" height="11" rx="1.8" /><rect x="16" y="4" width="4.5" height="7" rx="1.8" /></>,
  campanhas: <><path d="M4 10v4a1 1 0 0 0 1 1h3l6 4V5L8 9H5a1 1 0 0 0-1 1z" /><path d="M17.5 9a4 4 0 0 1 0 6" /></>,
  cadencias: <><circle cx="6" cy="6" r="2.3" /><circle cx="18" cy="12" r="2.3" /><circle cx="6" cy="18" r="2.3" /><path d="M8.2 6.9l7.6 4.2M15.8 12.9l-7.6 4.2" /></>,
  contatos: <><circle cx="9" cy="8.5" r="3.3" /><path d="M3.5 19a5.5 5.5 0 0 1 11 0" /><path d="M15.5 5.6a3.2 3.2 0 0 1 0 5.8M17.5 14.2A5.5 5.5 0 0 1 20.5 19" /></>,
  importar: <><path d="M12 4v11M7.5 10.5L12 15l4.5-4.5" /><path d="M4.5 15.5v2a2.5 2.5 0 0 0 2.5 2.5h10a2.5 2.5 0 0 0 2.5-2.5v-2" /></>,
  supressao: <><circle cx="12" cy="12" r="8.5" /><path d="M6 6l12 12" /></>,
  writeback: <><path d="M4.5 9a7.5 7.5 0 0 1 13.4-3.2L19.5 7.5" /><path d="M19.5 3.5v4h-4" /><path d="M19.5 15a7.5 7.5 0 0 1-13.4 3.2L4.5 16.5" /><path d="M4.5 20.5v-4h4" /></>,
  canais: <><path d="M5 12a7 7 0 0 1 14 0" /><path d="M8.5 12a3.5 3.5 0 0 1 7 0" /><circle cx="12" cy="12" r="1.2" /><path d="M12 13.2V20" /></>,
  config: <><circle cx="12" cy="12" r="3" /><path d="M12 3.5v2.2M12 18.3v2.2M20.5 12h-2.2M5.7 12H3.5M18 6l-1.6 1.6M7.6 16.4L6 18M18 18l-1.6-1.6M7.6 7.6L6 6" /></>,
  configurar: <><path d="M5 12.5l4 4 10-10" /></>,
  sair: <><path d="M14 4.5h3a2.5 2.5 0 0 1 2.5 2.5v10a2.5 2.5 0 0 1-2.5 2.5h-3" /><path d="M10 8l-4 4 4 4M6 12h9.5" /></>,
  sol: <><circle cx="12" cy="12" r="4" /><path d="M12 2.8v2M12 19.2v2M21.2 12h-2M4.8 12h-2M18.5 5.5l-1.4 1.4M6.9 17.1l-1.4 1.4M18.5 18.5l-1.4-1.4M6.9 6.9L5.5 5.5" /></>,
  lua: <path d="M19.5 14.5A7.5 7.5 0 0 1 9.5 4.5a7.5 7.5 0 1 0 10 10z" />,
  busca: <><circle cx="11" cy="11" r="6.5" /><path d="M16 16l4 4" /></>,
  menu: <path d="M4 7h16M4 12h16M4 17h10" />,
  sobe: <path d="M6 15l6-6 6 6" />,
  desce: <path d="M6 9l6 6 6-6" />,
  alerta: <><path d="M12 4.5l8.5 15h-17z" /><path d="M12 10v4M12 16.8v.2" /></>,
  seta: <path d="M9 6l6 6-6 6" />,
  check: <path d="M5 12.5l4.2 4.2L19 7" />,
  voltar: <path d="M15 6l-6 6 6 6" />,
  // Setup rápido (D72): o raio diz "atalho", não "configuração" genérica.
  raio: <path d="M13 3.5L5.5 13.5H12l-1 7 7.5-10H12z" />,
  // O agente de configuração: faísca, para não confundir com o agente de canal.
  faisca: <><path d="M12 4l1.6 4.4L18 10l-4.4 1.6L12 16l-1.6-4.4L6 10l4.4-1.6z" /><path d="M18.5 15.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z" /></>,
  enviar: <><path d="M4.5 12L19.5 4.5l-4 15-3.5-6z" /><path d="M12 13.5l7.5-9" /></>,
};

export function Ico({ nome, className = 'i' }: { nome: keyof typeof P | string; className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true">
      {P[nome] ?? P.inicio}
    </svg>
  );
}

/** A marca: o P da Prospecta terminando num ponto menta — a mensagem que sai. */
export function Marca() {
  return (
    <svg viewBox="0 0 32 32" aria-hidden="true">
      <rect width="32" height="32" rx="9" fill="#3A37C9" />
      <path d="M10 24V8.5h6.5a5 5 0 0 1 0 10H13" stroke="#FFFFFF" strokeWidth="3"
            strokeLinecap="round" strokeLinejoin="round" fill="none" />
      <circle cx="22.5" cy="23" r="2.6" fill="#3DF5A8" />
    </svg>
  );
}
