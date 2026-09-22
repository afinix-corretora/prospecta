/** Leituras e escritas do produto. Uma função por pergunta, nome do domínio.
 *
 * Nenhuma chamada filtra por tenant à mão: quem filtra é o RLS. Escrever o
 * filtro aqui também daria a impressão de que é ele que protege — e no dia em
 * que alguém esquecesse, ninguém notaria a diferença.
 */
import { sb } from './supabase';

export interface ProvedorCanal {
  slug: string;
  canal: 'whatsapp' | 'email' | 'sms' | 'instagram';
  nome: string;
  descricao: string;
  oficial: boolean;
  tem_adapter: boolean;
  campos: CampoProvedor[];
  docs_url: string | null;
  ordem: number;
}

export interface CampoProvedor {
  chave: string;
  rotulo: string;
  tipo: 'texto' | 'senha';
  obrigatorio: boolean;
  segredo: boolean;
  ajuda: string | null;
}

export interface Remetente {
  id: string;
  canal: ProvedorCanal['canal'];
  identificador: string;
  apelido: string | null;
  provedor: string;
  tipo_permitido: 'morna' | 'fria';
  quota_diaria: number;
  enviados_na_janela: number;
  estado: string;
  health_score: number;
  webhook_token: string;
  provider_server_id: string | null;
  config: Record<string, string>;
}

export interface Servidor {
  id: string;
  provedor: string;
  nome: string;
  base_url: string;
  admin_secret_id: string | null;
  ativo: boolean;
}

export interface Campanha {
  id: string;
  nome: string;
  tipo: 'morna' | 'fria';
  objetivo: string | null;
  ativa: boolean;
  canais_habilitados: string[];
  template_slug: string | null;
}

export interface Modelo {
  slug: string;
  nome: string;
  descricao: string;
  objetivo: string;
  tipo: 'morna' | 'fria';
  canais: string[];
  passos: unknown[];
  ordem: number;
}

export interface Agente {
  id: string;
  nome: string;
  canal: ProvedorCanal['canal'];
  papel: string;
  descricao: string;
  instrucoes: string;
  escalar_quando: string;
  limite_trocas: number;
  pronto: boolean;
  tenant_id: string | null;
}

export interface CredencialIA {
  id: string;
  nome: string;
  provedor: string;
  modelo: string;
  /** Só o ponteiro para o Vault. A chave não volta — nem para a tela. */
  chave_secret_id: string | null;
  config: Record<string, string>;
  ativo: boolean;
}

export interface ProvedorIA {
  slug: string;
  nome: string;
  descricao: string;
  campos: CampoProvedor[];
  modelos_sugeridos: string[];
  docs_url: string | null;
  ordem: number;
}

async function tabela<T>(nome: string, colunas: string, ordem?: string): Promise<T[]> {
  let q = sb.from(nome).select(colunas);
  if (ordem) q = q.order(ordem);
  const { data, error } = await q;
  if (error) throw error;
  return (data ?? []) as T[];
}

export const lerProvedoresCanal = () =>
  tabela<ProvedorCanal>('channel_provider_catalog',
    'slug, canal, nome, descricao, oficial, tem_adapter, campos, docs_url, ordem', 'ordem');

export const lerProvedoresIA = () =>
  tabela<ProvedorIA>('ai_provider_catalog',
    'slug, nome, descricao, campos, modelos_sugeridos, docs_url, ordem', 'ordem');

export const lerCredenciaisIA = () =>
  tabela<CredencialIA>('ai_credentials', 'id, nome, provedor, modelo, chave_secret_id, config, ativo', 'nome');

export const lerRemetentes = () =>
  tabela<Remetente>('sender_accounts',
    'id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, ' +
    'enviados_na_janela, estado, health_score, webhook_token, provider_server_id, config');

export const lerServidores = () =>
  tabela<Servidor>('provider_servers', 'id, provedor, nome, base_url, admin_secret_id, ativo', 'nome');

export const lerCampanhas = () =>
  tabela<Campanha>('campaigns', 'id, nome, tipo, objetivo, ativa, canais_habilitados, template_slug');

export const lerModelos = () =>
  tabela<Modelo>('campaign_templates', 'slug, nome, descricao, objetivo, tipo, canais, passos, ordem', 'ordem');

export const lerAgentes = () =>
  tabela<Agente>('agents',
    'id, nome, canal, papel, descricao, instrucoes, escalar_quando, limite_trocas, pronto, tenant_id');

// ---------------------------------------------------------------------------
// Escritas
// ---------------------------------------------------------------------------

/** Servidor + token de administração, com o segredo indo para o Vault (D26). */
export async function salvarServidor(dados: {
  tenant: string; provedor: string; nome: string; baseUrl: string; adminToken: string;
}): Promise<string> {
  const { data, error } = await sb.rpc('salvar_servidor_provedor', {
    p_tenant: dados.tenant,
    p_provedor: dados.provedor,
    p_nome: dados.nome,
    p_base_url: dados.baseUrl,
    // Vazio significa "não mexe no que já está guardado": o campo volta vazio
    // na tela porque segredo não é legível.
    p_admin_token: dados.adminToken.trim() || null,
  });
  if (error) throw error;
  return data as string;
}

/** Credencial de conta que já existe no provedor — Gupshup, Meta, SMTP. */
export async function salvarCredencial(senderId: string, credenciais: Record<string, string>) {
  const { error } = await sb.rpc('salvar_credencial_remetente', {
    p_sender_id: senderId,
    p_credenciais: credenciais,
  });
  if (error) throw error;
}

/** Conta sem credencial ainda: a linha primeiro, o segredo logo depois. */
export async function criarRemetente(dados: {
  tenant: string; canal: string; provedor: string; identificador: string;
  apelido: string; tipo: 'morna' | 'fria'; quota: number; config: Record<string, string>;
}): Promise<string> {
  const { data, error } = await sb
    .from('sender_accounts')
    .insert({
      tenant_id: dados.tenant,
      canal: dados.canal,
      provedor: dados.provedor,
      identificador: dados.identificador,
      apelido: dados.apelido || null,
      tipo_permitido: dados.tipo,
      quota_diaria: dados.quota,
      config: dados.config,
    })
    .select('id')
    .single();
  if (error) throw error;
  return data.id as string;
}

export interface InstanciaCriada {
  ok: boolean;
  erro?: string;
  sender_id?: string;
  webhook_url?: string;
  instancia?: string;
  qrcode?: string | null;
}

/** Cria a instância no provedor e devolve o chip pronto (D25). */
export async function provisionarInstancia(dados: {
  serverId: string; apelido: string; identificador: string;
  tipo: 'morna' | 'fria'; quota: number;
}): Promise<InstanciaCriada> {
  const { data, error } = await sb.functions.invoke('provisionar-instancia', {
    body: {
      server_id: dados.serverId,
      apelido: dados.apelido,
      identificador: dados.identificador,
      tipo_permitido: dados.tipo,
      quota_diaria: dados.quota,
    },
  });
  if (error) {
    // A edge function responde 4xx/5xx com um corpo que explica; o supabase-js
    // esconde isso atrás de "non-2xx status code".
    const corpo = await (error as { context?: Response }).context?.json?.().catch(() => null);
    return { ok: false, erro: corpo?.erro ?? error.message };
  }
  return data as InstanciaCriada;
}

/** Credencial de IA, com o catálogo separando segredo de config (D26).
 *
 * A tela manda tudo o que foi preenchido, num objeto só. Quem decide o que é
 * segredo é a função, lendo o catálogo — se a decisão morasse aqui, a UI
 * precisaria conhecer provedor, e é por não conhecer nenhum que ela não quebra
 * quando um provedor novo entra.
 */
export async function salvarCredencialIA(dados: {
  tenant: string; nome: string; provedor: string; modelo: string;
  campos: Record<string, string>;
}): Promise<string> {
  const { data, error } = await sb.rpc('salvar_credencial_ia', {
    p_tenant: dados.tenant,
    p_nome: dados.nome,
    p_provedor: dados.provedor,
    p_modelo: dados.modelo,
    p_campos: dados.campos,
  });
  if (error) throw error;
  return data as string;
}

/** Desligar não apaga: a credencial some do pool e o histórico continua. */
export async function alternarCredencialIA(id: string, ativo: boolean) {
  const { error } = await sb.from('ai_credentials').update({ ativo }).eq('id', id);
  if (error) throw error;
}

export async function criarCampanhaDeModelo(dados: {
  tenant: string; slug: string; nome: string; canais: string[] | null;
}) {
  const { data, error } = await sb.rpc('criar_campanha_de_modelo', {
    p_tenant: dados.tenant,
    p_slug: dados.slug,
    p_nome: dados.nome,
    p_canais: dados.canais,
  });
  if (error) throw error;
  return (data ?? [])[0] as { campaign_id: string; flow_version_id: string; passos_criados: number };
}

export async function criarTenant(nome: string, slug: string): Promise<string> {
  const { data, error } = await sb.rpc('criar_tenant', { p_nome: nome, p_slug: slug });
  if (error) throw error;
  return data as string;
}

// ---------------------------------------------------------------------------
// Importação de contatos (D32, D34)
// ---------------------------------------------------------------------------

export interface LinhaPrevista {
  linha: number;
  acao: 'criar' | 'atualizar' | 'recusar';
  contact_id: string | null;
  nome_atual: string | null;
  identidades_novas: number;
  identidades_existentes: number;
  identidades_suprimidas: number;
  problema: string | null;
}

/** O que `ingerir_contato` faria, sem gravar nada. */
export async function preverIngestao(
  tenant: string,
  linhas: { linha: number; identidades: { canal: string; valor_norm: string }[] }[],
): Promise<LinhaPrevista[]> {
  const { data, error } = await sb.rpc('prever_ingestao', {
    p_tenant: tenant,
    p_linhas: linhas,
  });
  if (error) throw error;
  return (data ?? []) as LinhaPrevista[];
}

export interface ContatoIngerido {
  contact_id: string;
  acao: 'criado' | 'atualizado';
  identidades_novas: number;
  identidades_existentes: number;
  identidades_suprimidas: number;
}

/**
 * Uma chamada por linha, de propósito.
 *
 * Um laço no servidor seria uma viagem só, mas colocaria as 500 linhas na
 * mesma transação: uma recusa no meio desfaz as 499 que já tinham passado.
 * Assim cada linha é a sua própria transação, o progresso é real e a linha que
 * falha não leva as outras junto. O custo é a latência, e é o custo certo —
 * importação é operação de uma vez por dia, não caminho quente.
 */
export async function ingerirContato(dados: {
  tenant: string; origem: string; identidades: unknown[];
  nome?: string; origemRef?: string; metadados?: Record<string, string>;
}): Promise<ContatoIngerido> {
  const { data, error } = await sb.rpc('ingerir_contato', {
    p_tenant: dados.tenant,
    p_origem: dados.origem,
    p_identidades: dados.identidades,
    p_nome: dados.nome ?? null,
    p_origem_ref: dados.origemRef ?? null,
    p_metadados: dados.metadados ?? {},
  });
  if (error) throw error;
  return (data ?? [])[0] as ContatoIngerido;
}
