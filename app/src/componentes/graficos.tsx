/**
 * Gráficos do painel, em SVG e sem biblioteca.
 *
 * Regras que valem para todos (método de dataviz):
 * - um eixo só; duas grandezas de escala diferente viram dois painéis com o
 *   mesmo eixo de tempo, nunca um segundo eixo Y;
 * - cor segue a série, e as cores (`--g-*`) foram conferidas pelo validador
 *   nos dois temas;
 * - curva monotônica: suaviza sem inventar pico que não houve;
 * - todo gráfico tem mira e dica ao passar o mouse, setas no teclado, e uma
 *   tabela oculta para quem lê com leitor de tela.
 */
import { useEffect, useId, useMemo, useRef, useState } from 'react';
import type { KeyboardEvent, PointerEvent, ReactNode } from 'react';

type Pt = [number, number];

/** Caminho suave e monotônico (Fritsch–Carlson) pelos pontos. */
export function curva(pts: Pt[]): string {
  const n = pts.length;
  if (!n) return '';
  if (n === 1) return `M${pts[0]![0]},${pts[0]![1]}`;
  const dx: number[] = [], m: number[] = [];
  for (let i = 0; i < n - 1; i++) {
    dx.push(pts[i + 1]![0] - pts[i]![0]);
    m.push((pts[i + 1]![1] - pts[i]![1]) / (dx[i] || 1));
  }
  const t: number[] = [m[0]!];
  for (let i = 1; i < n - 1; i++) t.push(m[i - 1]! * m[i]! <= 0 ? 0 : (m[i - 1]! + m[i]!) / 2);
  t.push(m[n - 2]!);
  for (let i = 0; i < n - 1; i++) {
    if (m[i] === 0) { t[i] = 0; t[i + 1] = 0; continue; }
    const a = t[i]! / m[i]!, b = t[i + 1]! / m[i]!, h = a * a + b * b;
    if (h > 9) { const k = 3 / Math.sqrt(h); t[i] = k * a * m[i]!; t[i + 1] = k * b * m[i]!; }
  }
  let d = `M${pts[0]![0]},${pts[0]![1]}`;
  for (let i = 0; i < n - 1; i++) {
    const [x0, y0] = pts[i]!, [x1, y1] = pts[i + 1]!, h = dx[i]! / 3;
    d += `C${x0 + h},${y0 + t[i]! * h} ${x1 - h},${y1 - t[i + 1]! * h} ${x1},${y1}`;
  }
  return d;
}

/** Topo "redondo" do eixo e quatro marcas: 0, ¼, ½, ¾, topo. */
function escala(max: number): number[] {
  if (max <= 0) return [0, 1];
  const bruto = max / 4;
  const p = 10 ** Math.floor(Math.log10(bruto));
  const passo = [1, 2, 2.5, 5, 10].map((k) => k * p).find((k) => k >= bruto) ?? 10 * p;
  const n = Math.ceil(max / passo);
  return Array.from({ length: n + 1 }, (_, i) => i * passo);
}

const fmt = new Intl.NumberFormat('pt-BR');
export const numero = (n: number) => fmt.format(n);

function useLargura<T extends HTMLElement>(): [React.RefObject<T | null>, number] {
  const ref = useRef<T>(null);
  const [w, setW] = useState(0);
  useEffect(() => {
    if (!ref.current) return;
    const ro = new ResizeObserver(([e]) => setW(Math.round(e!.contentRect.width)));
    ro.observe(ref.current);
    return () => ro.disconnect();
  }, []);
  return [ref, w];
}

/**
 * A curva do KPI, encostada na borda de baixo do cartão. Sem eixo e sem dica:
 * é a forma da semana, o número exato está logo acima.
 */
export function Tendencia({ valores, cor }: { valores: number[]; cor: string }) {
  const id = useId().replace(/:/g, '');
  const W = 300, H = 64, base = H - 2;
  const max = Math.max(0, ...valores) || 1;
  const pts: Pt[] = valores.map((v, i) => [
    valores.length > 1 ? (i / (valores.length - 1)) * W : W / 2,
    base - (v / max) * (H - 12),
  ]);
  const linha = curva(pts);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden="true">
      <defs>
        <linearGradient id={`t${id}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={cor} stopOpacity=".42" />
          <stop offset="1" stopColor={cor} stopOpacity="0" />
        </linearGradient>
      </defs>
      {pts.length > 1 && <path d={`${linha}L${W},${H}L0,${H}Z`} fill={`url(#t${id})`} />}
      <path d={linha} fill="none" stroke={cor} strokeWidth="2" vectorEffect="non-scaling-stroke" strokeLinecap="round" />
    </svg>
  );
}

export interface Serie {
  nome: string;
  cor: string;
  valores: number[];
  /** `linha` desenha curva com área; `barras`, colunas finas. */
  forma: 'linha' | 'barras';
}

/**
 * Painéis empilhados com o mesmo eixo de tempo — um por série, cada um com
 * a própria escala. É o que mantém "mensagens" e "respostas" legíveis juntas
 * sem um segundo eixo Y. A mira atravessa os dois, e a dica mostra os dois.
 */
export function GraficoNoTempo({ rotulos, series, alturas, extraDaDica, titulo, ultimoParcial }: {
  rotulos: string[];
  series: Serie[];
  alturas: number[];
  /** Linha a mais na dica (ex.: taxa de resposta do dia). */
  extraDaDica?(i: number): ReactNode;
  titulo: string;
  /** O último ponto é hoje, que ainda não acabou: o trecho até ele sai
   *  tracejado, para a queda do dia em curso não parecer queda de verdade. */
  ultimoParcial?: boolean;
}) {
  const [ref, W] = useLargura<HTMLDivElement>();
  const [foco, setFoco] = useState<number | null>(null);
  const id = useId().replace(/:/g, '');
  const n = rotulos.length;
  const esq = 40, dir = 8, entre = 44, baixo = 26, cabeca = 22;
  const larg = Math.max(0, W - esq - dir);
  // Respiro dentro da área: a primeira e a última barra cabem inteiras.
  const pad = 10;
  const x = (i: number) => esq + pad + (n > 1 ? (i / (n - 1)) * (larg - 2 * pad) : (larg - 2 * pad) / 2);
  const passoX = n > 1 ? (larg - 2 * pad) / (n - 1) : larg;

  const paineis = useMemo(() => {
    let topo = cabeca;
    return series.map((s, k) => {
      const h = alturas[k] ?? 120;
      const marcas = escala(Math.max(...s.valores, 0));
      const max = marcas[marcas.length - 1]!;
      // `topo` muda a cada painel: cada `y` guarda o seu, senão todos leriam o último.
      const t0 = topo;
      const y = (v: number) => t0 + h - (v / max) * h;
      const p = { s, topo: t0, h, marcas, y };
      topo += h + entre;
      return p;
    });
  }, [series, alturas]);
  const H = paineis.reduce((a, p) => a + p.h + entre, cabeca) - entre + baixo;

  // Quantos rótulos de data cabem sem encostar um no outro.
  const cada = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(larg / 64))));

  function mover(e: PointerEvent<SVGRectElement>) {
    const r = e.currentTarget.getBoundingClientRect();
    const i = Math.round(((e.clientX - r.left) / Math.max(1, r.width)) * (n - 1));
    setFoco(Math.min(n - 1, Math.max(0, i)));
  }
  function teclar(e: KeyboardEvent<SVGSVGElement>) {
    if (e.key === 'ArrowRight') { setFoco((f) => Math.min(n - 1, (f ?? -1) + 1)); e.preventDefault(); }
    if (e.key === 'ArrowLeft') { setFoco((f) => Math.max(0, (f ?? n) - 1)); e.preventDefault(); }
    if (e.key === 'Escape') setFoco(null);
  }

  const larguraBarra = Math.max(3, Math.min(14, passoX * 0.5));

  return (
    <div className="grafico" ref={ref}>
      {W > 0 && (
        <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} role="img" tabIndex={0}
             aria-label={`${titulo}. Use as setas para ler dia a dia.`}
             onKeyDown={teclar} onBlur={() => setFoco(null)}>
          <defs>
            {paineis.map((p, k) => (
              <linearGradient key={k} id={`a${id}${k}`} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0" stopColor={p.s.cor} stopOpacity=".34" />
                <stop offset="1" stopColor={p.s.cor} stopOpacity="0" />
              </linearGradient>
            ))}
            {/* Barras na mesma matéria das curvas: cor cheia no topo, esmaecendo. */}
            {paineis.map((p, k) => (
              <linearGradient key={`b${k}`} id={`b${id}${k}`} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0" stopColor={p.s.cor} stopOpacity="1" />
                <stop offset="1" stopColor={p.s.cor} stopOpacity=".35" />
              </linearGradient>
            ))}
          </defs>

          {paineis.map((p, k) => {
            const pts: Pt[] = p.s.valores.map((v, i) => [x(i), p.y(v)]);
            const linha = curva(pts);
            const cheia = ultimoParcial && pts.length > 2 ? curva(pts.slice(0, -1)) : linha;
            const resto = ultimoParcial && pts.length > 2 ? curva(pts.slice(-2)) : '';
            const comp = Math.round(larg * 2.4);
            return (
              <g key={k}>
                {/* Cada painel diz o que mede: são duas escalas, e a legenda
                    sozinha deixaria o olho ler os números como um eixo só. */}
                <text className="titulo-painel" x={esq} y={p.topo - 10}>{p.s.nome}</text>
                {p.marcas.map((m, j) => (
                  (j === 0 || j === p.marcas.length - 1 || p.marcas.length <= 4 || j % 2 === 0) && (
                    <g key={m}>
                      <line className="grade-y" x1={esq} x2={W - dir} y1={p.y(m)} y2={p.y(m)} />
                      {!(m === 0 && k < paineis.length - 1) && (
                        <text className="eixo" x={esq - 8} y={p.y(m) + 4} textAnchor="end">{numero(m)}</text>
                      )}
                    </g>
                  )
                ))}
                {p.s.forma === 'linha' ? (
                  <>
                    {n > 1 && (
                      <path className="area" d={`${linha}L${x(n - 1)},${p.topo + p.h}L${x(0)},${p.topo + p.h}Z`}
                            fill={`url(#a${id}${k})`} />
                    )}
                    <path className="traco desenha" d={cheia} stroke={p.s.cor}
                          style={{ ['--len' as string]: comp }} />
                    {resto && <path className="traco area" d={resto} stroke={p.s.cor} strokeDasharray="3 5" />}
                  </>
                ) : (
                  p.s.valores.map((v, i) => {
                    const h = p.topo + p.h - p.y(v);
                    if (h <= 0) return null;
                    const parcial = ultimoParcial && i === n - 1;
                    return (
                      <rect key={i} x={x(i) - larguraBarra / 2} y={p.y(v)} width={larguraBarra} height={h}
                            rx={larguraBarra / 2} fill={`url(#b${id}${k})`}
                            fillOpacity={parcial ? 0.45 : 1}
                            opacity={foco === null || foco === i ? 1 : 0.45} />
                    );
                  })
                )}
              </g>
            );
          })}

          {rotulos.map((r, i) => (i % cada === 0 || i === n - 1) && (n - 1 - i >= cada || i === n - 1) && (
            <text key={i} className="eixo" x={x(i)} y={H - 6}
                  textAnchor={i === 0 ? 'start' : i === n - 1 ? 'end' : 'middle'}>{r}</text>
          ))}

          {foco !== null && (
            <g pointerEvents="none">
              <line className="mira" x1={x(foco)} x2={x(foco)} y1={cabeca - 6} y2={H - baixo} />
              {paineis.map((p, k) => p.s.forma === 'linha' && (
                <circle key={k} cx={x(foco)} cy={p.y(p.s.valores[foco] ?? 0)} r={5}
                        fill={p.s.cor} stroke="var(--surface)" strokeWidth={2.5} />
              ))}
            </g>
          )}

          <rect x={esq} y={0} width={larg} height={H - baixo} fill="transparent"
                onPointerMove={mover} onPointerDown={mover} onPointerLeave={() => setFoco(null)} />
        </svg>
      )}

      {foco !== null && W > 0 && (
        <div className="dica" style={{
          left: Math.min(Math.max(x(foco), 90), W - 90),
          top: paineis[0] ? paineis[0].y(paineis[0].s.valores[foco] ?? 0) : 0,
        }} role="status">
          <b>{rotulos[foco]}{ultimoParcial && foco === n - 1 ? ' · hoje, parcial' : ''}</b>
          {series.map((s) => (
            <div key={s.nome}><span><i style={{ background: s.cor }} />{s.nome}</span><em>{numero(s.valores[foco] ?? 0)}</em></div>
          ))}
          {extraDaDica?.(foco)}
        </div>
      )}

      <table className="tabela-oculta">
        <caption>{titulo}</caption>
        <thead><tr><th>Dia</th>{series.map((s) => <th key={s.nome}>{s.nome}</th>)}</tr></thead>
        <tbody>
          {rotulos.map((r, i) => (
            <tr key={i}><td>{r}</td>{series.map((s) => <td key={s.nome}>{s.valores[i] ?? 0}</td>)}</tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Barras horizontais com rótulo e número: estágios do funil, canais. */
export function Barras({ itens, max }: {
  itens: { chave: string; rotulo: string; valor: number; cor: string; nota?: string; aoClicar?(): void }[];
  max?: number;
}) {
  const topo = Math.max(1, max ?? Math.max(0, ...itens.map((i) => i.valor)));
  return (
    <ul className="barras">
      {itens.map((i, k) => (
        <li key={i.chave}>
          <div className="rot">
            <span>{i.rotulo}</span>
            <b>{numero(i.valor)}</b>
            {i.nota && <small>{i.nota}</small>}
          </div>
          <div className="trilho" aria-hidden="true">
            <i style={{ width: `${(i.valor / topo) * 100}%`, background: i.cor, animationDelay: `${k * 40}ms` }} />
          </div>
        </li>
      ))}
    </ul>
  );
}

/** Anel de progresso — só para progresso de verdade (passos feitos). */
export function Anel({ feito, total, cor = 'var(--mint)' }: { feito: number; total: number; cor?: string }) {
  const r = 27, c = 2 * Math.PI * r;
  const frac = total ? feito / total : 0;
  return (
    <div className="anel" role="img" aria-label={`${feito} de ${total} prontos`}>
      <svg viewBox="0 0 64 64" aria-hidden="true">
        <circle cx="32" cy="32" r={r} fill="none" stroke="var(--surface-3)" strokeWidth="6" />
        <circle cx="32" cy="32" r={r} fill="none" stroke={cor} strokeWidth="6" strokeLinecap="round"
                strokeDasharray={`${c * frac} ${c}`} />
      </svg>
      <strong>{feito}/{total}</strong>
    </div>
  );
}
