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

import type {
  ContactSource, Colheita, ContatoLido, LinhaRecusada, ValorIgnorado,
} from './fonte.ts';
import { chaveDeColuna, lerCsv, separadorDe, vazia } from './csv.ts';
import { lerRegistro, PAPEIS_DE_IDENTIDADE } from './leitura.ts';
import type { Papel } from './leitura.ts';

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
      const valoresDaLinha = linhas[i] ?? [];
      if (vazia(valoresDaLinha)) continue;

      // A leitura da linha é a mesma do CRM (D64): aqui só se diz o papel de
      // cada coluna, pelo cabeçalho.
      const lido = lerRegistro(linha, cabecalho.map((coluna, j) => ({
        coluna,
        papel: papeis[j],
        chave: chaveDeColuna(coluna) || `coluna_${j + 1}`,
        valor: valoresDaLinha[j] ?? '',
      })));

      ignorados.push(...lido.ignorados);
      if (lido.tipo === 'recusa') recusadas.push(lido.recusa);
      else contatos.push(lido.contato);
    }

    return { origem: this.origem, contatos, recusadas, ignorados };
  }
}
