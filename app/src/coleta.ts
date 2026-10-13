// A coleta da empresa no construtor de agentes (D78b) — a parte da tela que
// não é desenho: o que está marcado, o que vai no pedido, o que falta para
// ler, que arquivo entra e como o rascunho volta ao texto do agente.
//
// Quem confere arquivo, endereço e @ é `adapters/coleta.ts`, o MESMO arquivo que
// a edge function lê: a tela barra antes de mandar, a function confere de
// novo, e as duas não têm como discordar (D32, D34). Pura, com teste em
// `tests/coleta_tela.test.ts`.

import { cabemJuntos, conferirArquivo, conferirEndereco, perfilDoInstagram } from '../../adapters/coleta.ts';
import type { TipoDeMaterial } from '../../adapters/coleta.ts';
import { leAnexos } from '../../adapters/ia-leitura.ts';
import { TETOS_DO_AGENTE } from '../../adapters/prompt-do-agente.ts';

export type FonteDaColeta = 'site' | 'instagram' | 'materiais';

export const FONTES_DA_COLETA: readonly { readonly slug: FonteDaColeta; readonly nome: string }[] = [
  { slug: 'site', nome: 'Site' },
  { slug: 'instagram', nome: 'Instagram' },
  { slug: 'materiais', nome: 'Materiais' },
];

export interface Anexo {
  readonly id: string;
  readonly nome: string;
  readonly tamanho: number;
  readonly tipo: TipoDeMaterial;
  /** O print do perfil é anexado no Instagram; o resto, em Materiais. */
  readonly origem: 'material' | 'instagram';
  readonly base64: string;
}

export interface EstadoDaColeta {
  readonly marcadas: ReadonlySet<FonteDaColeta>;
  readonly site: string;
  readonly handle: string;
  readonly perfil: string;
  readonly anexos: readonly Anexo[];
}

export const COLETA_VAZIA: EstadoDaColeta = { marcadas: new Set(), site: '', handle: '', perfil: '', anexos: [] };

/** Múltipla escolha: marcar uma não desmarca as outras. */
export function alternar(e: EstadoDaColeta, f: FonteDaColeta): EstadoDaColeta {
  const marcadas = new Set(e.marcadas);
  if (marcadas.has(f)) marcadas.delete(f); else marcadas.add(f);
  return { ...e, marcadas };
}

/** Os arquivos que vão no pedido: os das fontes MARCADAS. Desmarcar tira do pedido sem apagar. */
export function anexosQueVao(e: EstadoDaColeta): Anexo[] {
  return e.anexos.filter((a) => e.marcadas.has(a.origem === 'instagram' ? 'instagram' : 'materiais'));
}

/**
 * O arquivo novo entra? O MESMO `conferirArquivo` da edge function (extensão,
 * tamanho e os primeiros bytes), mais o conjunto: quantos e quanto, contando
 * os que já vão. No Instagram, só imagem — é o lugar do print.
 */
export function podeAnexar(
  e: EstadoDaColeta, novo: { nome: string; tamanho: number; cabeca: Uint8Array }, origem: Anexo['origem'],
): { ok: true; tipo: TipoDeMaterial } | { ok: false; motivo: string } {
  const conf = conferirArquivo(novo.nome, novo.tamanho, novo.cabeca);
  if (!conf.ok) return conf;
  if (origem === 'instagram' && conf.formato.tipo !== 'imagem') {
    return { ok: false, motivo: `"${novo.nome}": no Instagram entra print (JPG ou PNG); outros arquivos vão em Materiais` };
  }
  const marcada: FonteDaColeta = origem === 'instagram' ? 'instagram' : 'materiais';
  const vao = anexosQueVao({ ...e, marcadas: new Set([...e.marcadas, marcada]) });
  const demais = cabemJuntos([...vao.map((a) => a.tamanho), novo.tamanho]);
  if (demais) return { ok: false, motivo: `"${novo.nome}" não entrou: ${demais}` };
  return { ok: true, tipo: conf.formato.tipo };
}

/**
 * O que falta para ler, em palavras de quem preenche. Vazio é "pode ler".
 * Só o @ do Instagram não é material — a function responderia "nada lido"
 * depois de a pessoa esperar —, então ele falta quando é a ÚNICA coisa a ler.
 * Com o site ou um arquivo indo junto, o @ vai como contato, e não falta nada.
 */
export function oQueFaltaNaColeta(e: EstadoDaColeta, provedor: string | null): string[] {
  const falta: string[] = [];
  if (!e.marcadas.size) return ['marcar de onde colher'];
  if (!provedor) falta.push('a conta de IA que vai ler');
  const vao = anexosQueVao(e);
  const site = e.marcadas.has('site') ? e.site.trim() : '';
  let siteVai = false;
  if (e.marcadas.has('site')) {
    if (!site) falta.push('o endereço do site');
    else {
      const conf = conferirEndereco(site);
      if (!conf.ok) falta.push(conf.motivo);
      siteVai = conf.ok;
    }
  }
  const materiaisVao = e.marcadas.has('materiais') && vao.some((a) => a.origem === 'material');
  if (e.marcadas.has('instagram')) {
    const perfil = perfilDoInstagram(e.handle);
    const prints = vao.some((a) => a.origem === 'instagram');
    if (perfil.motivo) falta.push(`corrigir o @ do Instagram: "${e.handle.trim()}" ${perfil.motivo}`);
    else if (!e.perfil.trim() && !prints) {
      if (!perfil.handle) falta.push('o @, o texto do perfil ou um print');
      else if (!siteVai && !materiaisVao) {
        falta.push('o texto do perfil ou um print (só o @ não dá o que ler: o Instagram não deixa ler o perfil por robô)');
      }
    }
  }
  if (e.marcadas.has('materiais') && !materiaisVao) falta.push('pelo menos um arquivo');
  const demais = cabemJuntos(vao.map((a) => a.tamanho));
  if (demais) falta.push(demais);
  if (provedor && !leAnexos(provedor) && vao.some((a) => a.tipo === 'pdf' || a.tipo === 'imagem')) {
    falta.push(`uma conta que leia PDF e imagem (a escolhida é ${provedor}; Claude e OpenAI leem, e o OpenRouter, se o modelo ler) — ou tirar esses arquivos`);
  }
  return falta;
}

export interface PedidoDaColetaNaTela {
  credencial_id: string;
  empresa: string;
  site?: string;
  instagram?: { handle: string; texto: string };
  materiais?: { nome: string; origem: Anexo['origem']; base64: string }[];
}

/** O pedido leva só o que está marcado: o site digitado e depois desmarcado não é lido. */
export function pedidoDaColeta(e: EstadoDaColeta, credencialId: string, empresa: string): PedidoDaColetaNaTela {
  const vao = anexosQueVao(e);
  return {
    credencial_id: credencialId,
    empresa: empresa.trim(),
    ...(e.marcadas.has('site') && e.site.trim() ? { site: e.site.trim() } : {}),
    ...(e.marcadas.has('instagram') && (e.handle.trim() || e.perfil.trim())
      ? { instagram: { handle: e.handle.trim(), texto: e.perfil } } : {}),
    ...(vao.length ? { materiais: vao.map((a) => ({ nome: a.nome, origem: a.origem, base64: a.base64 })) } : {}),
  };
}

/**
 * O rascunho volta ao texto do agente pela mão da pessoa: no lugar do que
 * está lá, ou depois dele. Acima do teto do campo é recusado dizendo o
 * tamanho — cortar faria o fim do rascunho (onde costumam estar as condições)
 * sumir sem ninguém ver.
 */
export function aplicarRascunho(
  atual: string, rascunho: string, modo: 'usar' | 'acrescentar',
): { ok: true; texto: string } | { ok: false; motivo: string } {
  const novo = rascunho.trim();
  const texto = modo === 'usar' || !atual.trim() ? novo : `${atual.trimEnd()}\n\n${novo}`;
  const teto = TETOS_DO_AGENTE.contexto;
  if (texto.length > teto) {
    return { ok: false, motivo: `o texto ficaria com ${texto.length.toLocaleString('pt-BR')} caracteres, e o campo `
      + `aceita ${teto.toLocaleString('pt-BR')}: ${modo === 'acrescentar' ? 'use no lugar, ou encurte o texto atual antes' : 'leia menos material de uma vez'}` };
  }
  return { ok: true, texto };
}

export interface ContaParaLer { readonly id: string; readonly provedor: string; readonly ativo: boolean }

/**
 * Com que conta ler, de saída: a de "Compõe com" se ela serve; senão a
 * primeira que lê PDF e imagem; senão a primeira que serve. Serve = ligada e
 * com adapter. A pessoa troca na tela.
 */
export function contaPadraoDaLeitura<C extends ContaParaLer>(
  contas: readonly C[], temAdapter: (provedor: string) => boolean, escolhida: string | null,
): C | null {
  const servem = contas.filter((c) => c.ativo && temAdapter(c.provedor));
  return servem.find((c) => c.id === escolhida) ?? servem.find((c) => leAnexos(c.provedor)) ?? servem[0] ?? null;
}
