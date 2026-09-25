// `PlanilhaSource` — a fonte que o D1 nomeou e que não existia.
//
// Lê o CSV que a operação exporta e devolve contatos normalizados. Não escreve
// nada: quem escreve é `ingerir_contato`, e é por colher ser puro que a tela
// consegue mostrar a prévia antes de gravar.
//
// A parte que exige cuidado não é o CSV — é o cabeçalho. Planilha de operação
// não tem esquema: a coluna se chama `Telefone`, `Celular`, `WhatsApp`,
// `Fone 1`, `TELEFONE_2`, e obrigar a pessoa a renomear antes de importar é o
// tipo de atrito que faz a importação voltar a ser INSERT à mão.

import type { Canal } from './tipos.ts';
import type {
  ContactSource, Colheita, ContatoLido, IdentidadeLida, LinhaRecusada, ValorIgnorado,
} from './fonte.ts';
import { chaveDeColuna, lerCsv, separadorDe, vazia } from './csv.ts';
import { celularBrasileiro, normalizarTelefone, telefoneValido } from './telefone.ts';
import { emailValido, normalizarEmail } from './email.ts';
import { handleValido, normalizarHandle } from './instagram.ts';

/**
 * O que uma coluna significa. `telefone` não é canal: é um número sem canal
 * declarado, e decidir o que fazer com ele é a regra abaixo.
 */
type Papel = 'nome' | 'origem_ref' | 'whatsapp' | 'sms' | 'telefone' | 'email' | 'instagram';

/** Cabeçalhos vistos em planilha de verdade, já em forma de chave. */
const PAPEIS: Record<string, Papel> = {
  nome: 'nome', nome_completo: 'nome', nome_do_contato: 'nome', contato: 'nome',
  cliente: 'nome', razao_social: 'nome', responsavel: 'nome', lead: 'nome',

  id: 'origem_ref', codigo: 'origem_ref', cod: 'origem_ref', card: 'origem_ref',
  referencia: 'origem_ref', origem_ref: 'origem_ref', id_externo: 'origem_ref',

  whatsapp: 'whatsapp', whats: 'whatsapp', wpp: 'whatsapp', zap: 'whatsapp',

  sms: 'sms',

  telefone: 'telefone', celular: 'telefone', fone: 'telefone', tel: 'telefone',
  numero: 'telefone', telefone_celular: 'telefone', telefone_contato: 'telefone',

  email: 'email', e_mail: 'email', correio: 'email', email_contato: 'email',

  instagram: 'instagram', insta: 'instagram', ig: 'instagram',
  arroba: 'instagram', handle: 'instagram', perfil: 'instagram',
};

/**
 * `Telefone 2` e `E-mail 3` são a mesma coluna repetida, não colunas novas.
 * Sem isto a segunda vira metadado e o número dela se perde.
 */
function papelDe(cabecalho: string): Papel | undefined {
  const chave = chaveDeColuna(cabecalho);
  return PAPEIS[chave] ?? PAPEIS[chave.replace(/_[0-9]+$/, '')];
}

const PAPEIS_DE_IDENTIDADE: Papel[] = ['whatsapp', 'sms', 'telefone', 'email', 'instagram'];

export interface OpcoesPlanilha {
  /** Vai para `contacts.origem`. */
  readonly origem?: string;
  /** Força o separador quando o palpite do cabeçalho não serve. */
  readonly separador?: string;
}

export class PlanilhaSource implements ContactSource {
  readonly origem: string;
  private readonly texto: string;
  private readonly separador?: string;

  constructor(texto: string, opcoes: OpcoesPlanilha = {}) {
    this.texto = texto;
    this.separador = opcoes.separador;
    this.origem = opcoes.origem ?? 'planilha';
  }

  async colher(): Promise<Colheita> {
    return this.colherAgora();
  }

  /**
   * Versão síncrona. `colher()` é assíncrona porque a próxima fonte fala HTTP;
   * aqui não há espera nenhuma, e o teste fica mais direto sem fingir que há.
   */
  colherAgora(): Colheita {
    const linhas = lerCsv(this.texto, this.separador ?? separadorDe(this.texto));
    const cabecalho = linhas[0];
    if (!cabecalho) {
      throw new Error('planilha vazia: nem cabeçalho');
    }

    const papeis = cabecalho.map((c) => papelDe(c));

    // Arquivo sem nenhuma coluna de identidade é problema do arquivo, não das
    // linhas. Recusar 500 linhas uma a uma esconderia a causa atrás do volume.
    if (!papeis.some((p) => p && PAPEIS_DE_IDENTIDADE.includes(p))) {
      throw new Error(
        `nenhuma coluna de contato reconhecida em: ${cabecalho.join(', ')}. `
        + 'Esperado telefone, celular, whatsapp, sms, e-mail ou instagram.',
      );
    }

    const contatos: ContatoLido[] = [];
    const recusadas: LinhaRecusada[] = [];
    const ignorados: ValorIgnorado[] = [];

    for (let i = 1; i < linhas.length; i += 1) {
      // Numeração como a planilha mostra: o cabeçalho é a linha 1.
      const linha = i + 1;
      const celulas = linhas[i] ?? [];
      if (vazia(celulas)) continue;

      const valores: Record<string, string> = {};
      cabecalho.forEach((c, j) => { valores[c] = (celulas[j] ?? '').trim(); });

      const identidades: IdentidadeLida[] = [];
      const vistas = new Set<string>();
      const metadados: Record<string, string> = {};
      let nome: string | undefined;
      let origemRef: string | undefined;
      let ignoradasNaLinha = 0;

      const guardar = (canal: Canal, valor: string, valorNorm: string) => {
        // Duas colunas com o mesmo número é o caso normal (`Telefone` e
        // `WhatsApp` preenchidos iguais), e o índice único recusaria a segunda.
        const chave = `${canal}|${valorNorm}`;
        if (vistas.has(chave)) return;
        vistas.add(chave);
        identidades.push({ canal, valor, valorNorm });
      };

      const ignorar = (coluna: string, valor: string, motivo: string) => {
        ignoradasNaLinha += 1;
        ignorados.push({ linha, coluna, valor, motivo });
      };

      cabecalho.forEach((coluna, j) => {
        const bruto = (celulas[j] ?? '').trim();
        const papel = papeis[j];

        if (!papel) {
          // Coluna que o motor não entende ainda é informação da operação:
          // "plano atual", "corretor". Vira metadado em vez de sumir.
          if (bruto) metadados[chaveDeColuna(coluna) || `coluna_${j + 1}`] = bruto;
          return;
        }

        if (!bruto) return;

        switch (papel) {
          case 'nome':
            nome = nome ?? bruto;
            return;
          case 'origem_ref':
            origemRef = origemRef ?? bruto;
            return;
          case 'email':
            if (emailValido(bruto)) guardar('email', bruto, normalizarEmail(bruto));
            else ignorar(coluna, bruto, 'não é um endereço de e-mail');
            return;
          case 'instagram':
            if (handleValido(bruto)) guardar('instagram', bruto, normalizarHandle(bruto));
            else ignorar(coluna, bruto, 'não é um @ de Instagram');
            return;
          case 'whatsapp':
          case 'sms':
            // Coluna que diz o canal decide sozinha: quem escreveu "WhatsApp"
            // no cabeçalho está afirmando que o número tem WhatsApp.
            if (telefoneValido(bruto)) guardar(papel, bruto, normalizarTelefone(bruto));
            else ignorar(coluna, bruto, 'não é um telefone discável');
            return;
          case 'telefone':
            // Coluna genérica não declara canal. Celular entra nos dois, que é
            // o que "telefone" significa na prática; fixo não entra em nenhum,
            // porque o motor não tem como falar com ele — e prometer WhatsApp
            // num fixo seria o roteador escolhendo um destino que não existe.
            if (!telefoneValido(bruto)) {
              ignorar(coluna, bruto, 'não é um telefone discável');
            } else if (!celularBrasileiro(bruto)) {
              ignorar(coluna, bruto, 'telefone fixo não recebe WhatsApp nem SMS');
            } else {
              const norm = normalizarTelefone(bruto);
              guardar('whatsapp', bruto, norm);
              guardar('sms', bruto, norm);
            }
            return;
        }
      });

      if (identidades.length === 0) {
        recusadas.push({
          linha,
          motivo: ignoradasNaLinha > 0
            ? 'nenhum contato utilizável: o que havia não passou na conferência'
            : 'linha sem telefone, e-mail ou @ preenchido',
          valores,
        });
        continue;
      }

      contatos.push({ nome, origemRef, identidades, metadados, linha });
    }

    return { origem: this.origem, contatos, recusadas, ignorados };
  }
}
