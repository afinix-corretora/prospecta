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
