// Ler um registro de contato: a regra que a planilha e o CRM dividem (D64).
//
// Nasceu dentro de `planilha.ts` e saiu de lá quando a segunda fonte chegou.
// Duas fontes com duas leituras seriam a segunda normalização do D32 com
// outro nome: o mesmo celular entrando como WhatsApp por uma porta e sumindo
// pela outra. Aqui mora a única resposta para "este valor, nesta coluna, vira
// que identidade?" — a fonte só diz qual é o papel de cada coluna.

import type { Canal } from './tipos.ts';
import type { ContatoLido, IdentidadeLida, LinhaRecusada, ValorIgnorado } from './fonte.ts';
import { celularBrasileiro, normalizarTelefone, telefoneValido } from './telefone.ts';
import { emailValido, normalizarEmail } from './email.ts';
import { handleValido, normalizarHandle } from './instagram.ts';

/**
 * O que uma coluna significa. `telefone` não é canal: é um número sem canal
 * declarado, e decidir o que fazer com ele é a regra abaixo. `variavel` é
 * dado que a cadência pode citar (`{{plano}}`) e vai para os metadados.
 */
export type Papel =
  | 'nome' | 'origem_ref' | 'whatsapp' | 'sms' | 'telefone' | 'email' | 'instagram' | 'variavel';

export const PAPEIS_DE_IDENTIDADE: readonly Papel[] = ['whatsapp', 'sms', 'telefone', 'email', 'instagram'];

/** Uma célula: a coluna como a fonte a chama, o papel dela e o valor bruto. */
export interface Celula {
  readonly coluna: string;
  /** `undefined` = coluna que o motor não entende; vira metadado com `chave`. */
  readonly papel?: Papel;
  /** Chave do metadado, quando a célula vira metadado. */
  readonly chave: string;
  readonly valor: string;
}

export type ResultadoDaLeitura =
  | { readonly tipo: 'contato'; readonly contato: ContatoLido; readonly ignorados: ValorIgnorado[] }
  | { readonly tipo: 'recusa'; readonly recusa: LinhaRecusada; readonly ignorados: ValorIgnorado[] };

export function lerRegistro(linha: number, celulas: readonly Celula[]): ResultadoDaLeitura {
  const identidades: IdentidadeLida[] = [];
  const vistas = new Set<string>();
  const metadados: Record<string, string> = {};
  const ignorados: ValorIgnorado[] = [];
  const valores: Record<string, string> = {};
  let nome: string | undefined;
  let origemRef: string | undefined;

  const guardar = (canal: Canal, valor: string, valorNorm: string) => {
    // Duas colunas com o mesmo número é o caso normal (`Telefone` e
    // `WhatsApp` preenchidos iguais), e o índice único recusaria a segunda.
    const chave = `${canal}|${valorNorm}`;
    if (vistas.has(chave)) return;
    vistas.add(chave);
    identidades.push({ canal, valor, valorNorm });
  };

  const ignorar = (coluna: string, valor: string, motivo: string) => {
    ignorados.push({ linha, coluna, valor, motivo });
  };

  for (const c of celulas) {
    const bruto = (c.valor ?? '').trim();
    valores[c.coluna] = bruto;

    if (!c.papel || c.papel === 'variavel') {
      // Coluna que o motor não entende ainda é informação da operação:
      // "plano atual", "corretor". Vira metadado em vez de sumir.
      if (bruto) metadados[c.chave] = bruto;
      continue;
    }

    if (!bruto) continue;

    switch (c.papel) {
      case 'nome':
        nome = nome ?? bruto;
        break;
      case 'origem_ref':
        origemRef = origemRef ?? bruto;
        break;
      case 'email':
        if (emailValido(bruto)) guardar('email', bruto, normalizarEmail(bruto));
        else ignorar(c.coluna, bruto, 'não é um endereço de e-mail');
        break;
      case 'instagram':
        if (handleValido(bruto)) guardar('instagram', bruto, normalizarHandle(bruto));
        else ignorar(c.coluna, bruto, 'não é um @ de Instagram');
        break;
      case 'whatsapp':
      case 'sms':
        // Coluna que diz o canal decide sozinha: quem escreveu "WhatsApp"
        // no cabeçalho está afirmando que o número tem WhatsApp.
        if (telefoneValido(bruto)) guardar(c.papel, bruto, normalizarTelefone(bruto));
        else ignorar(c.coluna, bruto, 'não é um telefone discável');
        break;
      case 'telefone':
        // Coluna genérica não declara canal. Celular entra nos dois, que é
        // o que "telefone" significa na prática; fixo não entra em nenhum,
        // porque o motor não tem como falar com ele — e prometer WhatsApp
        // num fixo seria o roteador escolhendo um destino que não existe.
        if (!telefoneValido(bruto)) {
          ignorar(c.coluna, bruto, 'não é um telefone discável');
        } else if (!celularBrasileiro(bruto)) {
          ignorar(c.coluna, bruto, 'telefone fixo não recebe WhatsApp nem SMS');
        } else {
          const norm = normalizarTelefone(bruto);
          guardar('whatsapp', bruto, norm);
          guardar('sms', bruto, norm);
        }
        break;
    }
  }

  if (identidades.length === 0) {
    return {
      tipo: 'recusa',
      recusa: {
        linha,
        motivo: ignorados.length > 0
          ? 'nenhum contato utilizável: o que havia não passou na conferência'
          : 'linha sem telefone, e-mail ou @ preenchido',
        valores,
      },
      ignorados,
    };
  }

  return {
    tipo: 'contato',
    contato: { nome, origemRef, identidades, metadados, linha },
    ignorados,
  };
}
