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

// ---------------------------------------------------------------------------
// Contatos e inscrição em campanha (D35)
// ---------------------------------------------------------------------------

export interface IdentidadeDoContato {
  canal: ProvedorCanal['canal'];
  valor: string;
  valor_norm: string;
  valida: boolean;
}

export interface Contato {
  id: string;
  nome: string | null;
  origem: string;
  origem_ref: string | null;
  criado_em: string;
  contact_identities: IdentidadeDoContato[];
}

/**
 * A busca é por nome e por identidade, porque as duas são como se procura
 * alguém: pelo nome que a planilha trouxe, ou pelo número que apareceu no
 * WhatsApp. `valor_norm` está no filtro de propósito — quem digita
 * "(15) 99123-4567" não acha nada procurando pelo que está gravado.
 */
export async function lerContatos(busca = '', limite = 200): Promise<Contato[]> {
  const colunas = 'id, nome, origem, origem_ref, criado_em, '
    + 'contact_identities(canal, valor, valor_norm, valida)';
  let q = sb.from('contacts').select(colunas).order('criado_em', { ascending: false }).limit(limite);

  const termo = busca.trim();
  if (termo) {
    const digitos = termo.replace(/\D/g, '');
    const alvos = [`nome.ilike.%${termo}%`];
    if (digitos.length >= 4) alvos.push(`contact_identities.valor_norm.ilike.%${digitos}%`);
    else alvos.push(`contact_identities.valor_norm.ilike.%${termo.toLowerCase()}%`);
    q = q.or(alvos.join(','));
  }

  const { data, error } = await q;
  if (error) throw error;
  return (data ?? []) as unknown as Contato[];
}

export interface VersaoDeFlow {
  id: string;
  versao: number;
  flow_nome: string;
  canais: ProvedorCanal['canal'][];
  passos: number;
}

/**
 * As versões de flow publicadas, com os canais que cada uma usa.
 *
 * O canal aparece aqui porque é o que decide se a inscrição vale: flow de
 * e-mail numa campanha só de WhatsApp não manda nada para ninguém, e o
 * operador não tem como saber isso olhando o nome.
 */
export async function lerVersoesDeFlow(): Promise<VersaoDeFlow[]> {
  const { data, error } = await sb
    .from('flow_versions')
    .select('id, versao, flows(nome), flow_steps(canal, ordem)')
    .order('publicado_em', { ascending: false });
  if (error) throw error;

  return (data ?? []).map((v) => {
    const linha = v as unknown as {
      id: string; versao: number;
      flows: { nome: string } | { nome: string }[] | null;
      flow_steps: { canal: ProvedorCanal['canal'] }[] | null;
    };
    const flow = Array.isArray(linha.flows) ? linha.flows[0] : linha.flows;
    const passos = linha.flow_steps ?? [];
    return {
      id: linha.id,
      versao: linha.versao,
      flow_nome: flow?.nome ?? '(sem nome)',
      canais: [...new Set(passos.map((p) => p.canal))],
      passos: passos.length,
    };
  });
}

export interface ContatoPrevisto {
  contact_id: string;
  nome: string | null;
  acao: 'inscrever' | 'ja_inscrito' | 'suprimido' | 'sem_canal' | 'desconhecido';
  canais_alcancaveis: ProvedorCanal['canal'][] | null;
  problema: string | null;
}

/** O que `inscrever` faria com cada contato, sem inscrever ninguém. */
export async function preverInscricao(dados: {
  tenant: string; campanha: string; versao: string; contatos: string[];
}): Promise<ContatoPrevisto[]> {
  const { data, error } = await sb.rpc('prever_inscricao', {
    p_tenant: dados.tenant,
    p_campaign_id: dados.campanha,
    p_flow_version_id: dados.versao,
    p_contatos: dados.contatos,
  });
  if (error) throw error;
  return (data ?? []) as ContatoPrevisto[];
}

/**
 * Devolve o id do enrollment, ou `null` quando o contato está suprimido — e o
 * nulo mudo é exatamente o motivo de a prévia existir. Uma chamada por
 * contato, pela mesma razão da importação: a que falha não leva as outras.
 */
export async function inscrever(dados: {
  contato: string; campanha: string; versao: string;
}): Promise<string | null> {
  const { data, error } = await sb.rpc('inscrever', {
    p_contact_id: dados.contato,
    p_campaign_id: dados.campanha,
    p_flow_version_id: dados.versao,
  });
  if (error) throw error;
  return (data ?? null) as string | null;
}

// ---------------------------------------------------------------------------
// Painel da campanha (D36)
// ---------------------------------------------------------------------------

export interface ResumoDaCampanha {
  inscritos_ativos: number;
  inscritos_pausados: number;
  encerrados: number;
  por_motivo: Record<string, number>;
  mensagens: number;
  por_status: Record<string, number>;
  respostas: number;
  cliques: number;
  vencidos_agora: number;
  proximo_disparo: string | null;
}

export async function lerResumoDaCampanha(
  tenant: string, campanha: string,
): Promise<ResumoDaCampanha | null> {
  const { data, error } = await sb.rpc('resumo_da_campanha', {
    p_tenant: tenant, p_campaign_id: campanha,
  });
  if (error) throw error;
  return ((data ?? [])[0] as ResumoDaCampanha) ?? null;
}

export interface EventoDaCampanha {
  ocorrido_em: string;
  contato: string;
  canal: ProvedorCanal['canal'];
  tipo: string;
  status: 'pendente' | 'simulado' | 'enviado' | 'falha' | 'cancelado';
  remetente: string;
  destino: string;
}

export async function lerEventosDaCampanha(
  tenant: string, campanha: string, limite = 100,
): Promise<EventoDaCampanha[]> {
  const { data, error } = await sb.rpc('eventos_da_campanha', {
    p_tenant: tenant, p_campaign_id: campanha, p_limite: limite,
  });
  if (error) throw error;
  return (data ?? []) as EventoDaCampanha[];
}

// ---------------------------------------------------------------------------
// Supressão (D41)
// ---------------------------------------------------------------------------

export interface Supressao {
  id: string;
  contact_id: string | null;
  canal: ProvedorCanal['canal'] | null;
  valor_norm: string | null;
  motivo: string;
  criado_em: string;
  contacts: { nome: string | null } | null;
}

export const lerSupressoes = (limite = 500) =>
  tabela<Supressao>('suppression',
    'id, contact_id, canal, valor_norm, motivo, criado_em, contacts(nome)', 'criado_em')
    .then((l) => l.slice(-limite).reverse());

/**
 * Uma supressão por endereço: vale para quem já está na base e para quem
 * ainda vai entrar, porque `esta_suprimido` casa por `(canal, valor_norm)`
 * independentemente de existir contato.
 *
 * Não há função de remover, e não é esquecimento: `suppression` é imutável
 * por gatilho. Tirar alguém de lá seria voltar a falar com quem pediu para
 * parar, e isso não é operação de tela.
 */
export async function suprimirEndereco(dados: {
  tenant: string; canal: string; valorNorm: string; motivo: string;
}): Promise<'nova' | 'ja_existia'> {
  const { error } = await sb.from('suppression').insert({
    tenant_id: dados.tenant,
    canal: dados.canal,
    valor_norm: dados.valorNorm,
    motivo: dados.motivo,
  });
  // 23505 é violação de índice único: já estava suprimido, que é sucesso do
  // ponto de vista de quem pediu — o endereço não recebe nada de qualquer jeito.
  if (error && (error as { code?: string }).code === '23505') return 'ja_existia';
  if (error) throw error;
  return 'nova';
}

/** Supressão do contato inteiro: nenhum canal, nunca mais. */
export async function suprimirContato(dados: {
  tenant: string; contato: string; motivo: string;
}): Promise<'nova' | 'ja_existia'> {
  const { error } = await sb.from('suppression').insert({
    tenant_id: dados.tenant,
    contact_id: dados.contato,
    motivo: dados.motivo,
  });
  if (error && (error as { code?: string }).code === '23505') return 'ja_existia';
  if (error) throw error;
  return 'nova';
}
