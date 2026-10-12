// O prompt do agente num lugar só (D76): o que muda por canal, a persona e o
// objetivo, e os freios que o modelo não controla.
//
// As asserções que importam:
//
//   - o bloco do canal entra no pedido, e o freio usa o MESMO limite que o
//     pedido declara (o freio não pode desligar por omissão: canal desconhecido
//     lança, em vez de `length > undefined`);
//   - pede-se menos do que o freio aceita;
//   - pedido de saída que a blacklist não pegou vira escalada, nunca uma
//     confirmação que ninguém gravou;
//   - "recebe resposta" bate com os adapters: o SMS não traz resposta e o
//     Instagram não tem adapter — a tela não pode oferecê-los como se o
//     agente respondesse por ali;
//   - nenhum texto do catálogo dispara o próprio freio de dado sensível, e todo
//     roteiro passa da trava de 120 caracteres de `agents.instrucoes`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  agenteNovo, alvoDeTamanho, aplicarFreios, assuntoDaConversa, CANAIS, CONTEXTO_MINIMO, limiteEfetivo,
  MARCA_ESCALAR, MARCA_SAIR, metadadosParaOModelo, montarPedido, nomeDeApresentacao, normalizarSaida,
  objetivoCombina, objetivoDoModelo, OBJETIVOS, PERSONAS, semAcento, tokensParaCompor,
} from '../adapters/prompt-do-agente.ts';
import type { EntradaDoPrompt } from '../adapters/prompt-do-agente.ts';
import { criarAdapter, PROVEDORES_POR_CANAL } from '../adapters/registro.ts';

const novo = agenteNovo({ persona: 'consultiva', objetivo: 'resgate', empresa: 'Afinix Corretora' });

const ANA: EntradaDoPrompt = {
  canal: 'whatsapp', texto: 'tenho interesse, como funciona?',
  agente_nome: 'Ana', ...novo,
  contexto: 'Falamos em nome da Afinix Corretora, em São José do Rio Preto. Oferecemos planos de saúde '
    + 'individuais e empresariais. O próximo passo é uma ligação de 15 minutos com um especialista.',
  proibido: ['garantimos'], tamanho_maximo: null,
  contato_nome: 'Marina', metadados: null, campanha: 'Resgate Outubro',
  historico: [{ de: 'nos', texto: 'Oi Marina, ainda pensa no plano?' }, { de: 'pessoa', texto: 'tenho interesse, como funciona?' }],
};

test('pedido: persona, objetivo, empresa, canal e regras, nesta ordem', () => {
  const { sistema } = montarPedido(ANA);
  const ordem = ['Você é Ana, assistente de relacionamento', 'COMO VOCÊ FALA', 'O QUE VOCÊ FAZ',
    'SOBRE A EMPRESA E A OFERTA', 'COMO ESTE CANAL FUNCIONA (WhatsApp)', 'REGRAS QUE VALEM SEMPRE'];
  const posicoes = ordem.map((x) => sistema.indexOf(x));
  assert.ok(posicoes.every((p) => p >= 0), `faltou seção: ${ordem[posicoes.indexOf(-1)]}`);
  assert.deepEqual([...posicoes].sort((a, b) => a - b), posicoes, 'as seções saíram fora de ordem');
  assert.match(sistema, /Afinix Corretora, em São José do Rio Preto/);
  assert.match(sistema, /uma a três frases/);
  assert.doesNotMatch(sistema, /INSTRUÇÕES DO CLIENTE/, 'agente novo tem objetivo, e o título diz o que ele faz');
});

test('pedido: o canal muda o bloco e o limite; o agente só encurta', () => {
  for (const canal of ['whatsapp', 'email', 'sms', 'instagram'] as const) {
    const p = montarPedido({ ...ANA, canal });
    assert.equal(p.limite, CANAIS[canal].limite, canal);
    assert.match(p.sistema, new RegExp(`COMO ESTE CANAL FUNCIONA \\(${CANAIS[canal].nome}\\)`));
    assert.match(p.sistema, new RegExp(`até ${alvoDeTamanho(p.limite)} caracteres \\(nunca mais de ${p.limite}\\)`));
    for (const r of CANAIS[canal].regras) assert.ok(p.sistema.includes(r), `${canal}: ${r}`);
  }
  // Agente que pediu menos que o canal: vale o dele. Que pediu mais: vale o do canal.
  assert.equal(limiteEfetivo('email', 500), 500);
  assert.equal(limiteEfetivo('sms', 700), 160, 'o SMS da Rita (700) deixa de passar de 160');
  assert.equal(limiteEfetivo('whatsapp', null), 700);
  assert.ok(alvoDeTamanho(160) < 160);
});

test('freio: o mesmo limite do pedido, por canal — e canal desconhecido lança, nunca desliga', () => {
  const sms = { ...ANA, canal: 'sms' };
  assert.equal(aplicarFreios('a'.repeat(160), sms).situacao, 'pronto');
  assert.equal(aplicarFreios('a'.repeat(161), sms).situacao, 'bloqueado');
  assert.equal(aplicarFreios('a'.repeat(1500), { ...ANA, canal: 'email' }).situacao, 'pronto');
  assert.throws(() => aplicarFreios('oi', { ...ANA, canal: 'telegram' }), /sem comportamento declarado/);
  assert.throws(() => montarPedido({ ...ANA, canal: 'telegram' }), /sem comportamento declarado/);
});

test('saída: o pedido vira marca, e a marca vira pessoa — nunca "não vamos mais te contatar"', () => {
  const { sistema } = montarPedido(ANA);
  assert.match(sistema, new RegExp(`não receber mais mensagens, responda exatamente \\${MARCA_SAIR.slice(0, -1)}\\]`));
  const f = aplicarFreios(MARCA_SAIR, ANA);
  assert.equal(f.situacao, 'escalar');
  assert.match((f as { motivo: string }).motivo, /Supressão/);
  // Mesmo com texto em volta, a marca não sai como mensagem.
  assert.equal(aplicarFreios(`Tudo bem! ${MARCA_SAIR}`, ANA).situacao, 'escalar');
  assert.equal(aplicarFreios(MARCA_ESCALAR, ANA).situacao, 'escalar');
});

test('freio: vazio é barrado; dado sensível e proibido continuam barrados', () => {
  assert.equal(aplicarFreios('   ', ANA).situacao, 'bloqueado');
  assert.equal(aplicarFreios('Me passa o CPF?', ANA).situacao, 'bloqueado');
  assert.equal(aplicarFreios('Nós GARANTIMOS o melhor.', ANA).situacao, 'bloqueado');
});

test('regras: não inventar o que não está escrito acima, e saúde não se pergunta', () => {
  const { sistema } = montarPedido(ANA);
  assert.match(sistema, /Não invente preço, cobertura, prazo, carência, nome de empresa, produto nem condição que não esteja escrito acima/);
  assert.match(sistema, /Não pergunte sobre doença, tratamento ou condição de saúde/);
  assert.match(sistema, /assistente virtual da equipe/);
  assert.match(sistema, /se algo acima disser o contrário, valem estas e as do canal/);
});

test('e-mail: a resposta segue no assunto da conversa, pelo mesmo marcador que o adapter lê', () => {
  const comAssunto = montarPedido({
    ...ANA, canal: 'email',
    historico: [{ de: 'nos', texto: 'Assunto: Seu plano de saúde\n\nOi Marina, separei duas opções.' },
                { de: 'pessoa', texto: 'Quero saber mais' }],
  });
  assert.match(comAssunto.sistema, /"Assunto: Re: Seu plano de saúde"/);
  assert.equal(assuntoDaConversa([{ de: 'nos', texto: 'Assunto: Re: X\n\ncorpo' }]), 'Re: X', 'sem Re: Re:');
  const semAssunto = montarPedido({ ...ANA, canal: 'email' });
  assert.match(semAssunto.sistema, /Não escreva linha de assunto/);
});

test('nome: o rótulo de lista não vira apresentação', () => {
  assert.equal(nomeDeApresentacao('Ana — resgate no WhatsApp'), 'Ana');
  assert.equal(nomeDeApresentacao('Ana-Maria'), 'Ana-Maria');
  assert.match(montarPedido({ ...ANA, agente_nome: 'Ana — resgate no WhatsApp' }).sistema, /^Você é Ana, /);
});

test('catálogo: roteiros cabem na trava do banco e não disparam o próprio freio', () => {
  const slugs = new Set<string>();
  for (const o of OBJETIVOS) {
    assert.ok(o.roteiro.trim().length >= 120, `${o.slug}: roteiro curto demais para agents.instrucoes`);
    assert.ok(!slugs.has(o.slug)); slugs.add(o.slug);
    for (const t of [o.roteiro, o.escalar_quando, o.resumo]) {
      const f = aplicarFreios(t, { canal: 'email', proibido: [], tamanho_maximo: null });
      assert.equal(f.situacao, 'pronto', `${o.slug}: ${f.situacao === 'pronto' ? '' : f.motivo}`);
    }
    assert.ok(o.limite_trocas >= 1 && o.limite_trocas <= 100);
    assert.ok(o.combina.length > 0);
  }
  for (const p of PERSONAS) {
    // A persona é só voz: tamanho e formato são do canal.
    assert.doesNotMatch(semAcento(p.tom), /mensagens? curtas?|paragrafo|caracteres/, `${p.slug} fala de formato`);
  }
});

test('agente novo: pré-preenchido pela persona e pelo objetivo, com a empresa no contexto', () => {
  const a = agenteNovo({ persona: 'executiva', objetivo: 'prospeccao_fria', empresa: 'Afinix Corretora' });
  assert.equal(a.tom, PERSONAS.find((p) => p.slug === 'executiva')!.tom);
  assert.equal(a.instrucoes, OBJETIVOS.find((o) => o.slug === 'prospeccao_fria')!.roteiro);
  assert.equal(a.contexto, 'Falamos em nome de Afinix Corretora.');
  assert.ok(a.contexto.length < CONTEXTO_MINIMO, 'só o nome não basta: a tela pede para completar');
});

test('objetivo × campanha: base própria numa lista fria é conflito', () => {
  assert.equal(objetivoCombina('fria', 'resgate'), 'conflito');
  assert.equal(objetivoCombina('morna', 'prospeccao_fria'), 'conflito');
  assert.equal(objetivoCombina('fria', 'agendamento'), 'ok');
  assert.equal(objetivoCombina('fria', null), 'ok', 'agente antigo não é julgado');
  assert.equal(objetivoDoModelo('resgate-multicanal', 'morna'), 'resgate');
  assert.equal(objetivoDoModelo('prospeccao-fria-multicanal', 'fria'), 'prospeccao_fria');
  assert.equal(objetivoDoModelo('renovacao-apolice', 'morna'), 'renovacao');
  assert.equal(objetivoDoModelo('reengajamento', 'morna'), 'follow_up');
  assert.equal(objetivoDoModelo(null, 'fria'), 'prospeccao_fria');
  for (const s of ['resgate-multicanal', 'prospeccao-fria', 'renovacao-apolice', 'reengajamento', null]) {
    assert.ok(OBJETIVOS.some((o) => o.slug === objetivoDoModelo(s, 'morna')));
  }
});

test('recebe resposta: bate com os adapters — o SMS não traz resposta, o Instagram não tem adapter', () => {
  assert.equal(CANAIS.instagram.recebeResposta, PROVEDORES_POR_CANAL.instagram.length > 0);
  // Se um provedor de SMS um dia trouxer resposta, este teste acende e o
  // catálogo precisa mudar junto: a tela passaria a oferecer o SMS ao agente.
  const algumTraz = PROVEDORES_POR_CANAL.sms.some((p) => {
    const corpo = { from: '5517999999999', message: 'SIM', text: 'SIM', Content: 'SIM', tipo: 'mo' };
    return criarAdapter(p).normalizeWebhook(corpo).some((e) => e.tipo === 'respondido');
  });
  assert.equal(CANAIS.sms.recebeResposta, algumTraz);
  assert.equal(CANAIS.whatsapp.recebeResposta, true);
  assert.equal(CANAIS.email.recebeResposta, true);
  for (const c of Object.values(CANAIS)) if (!c.recebeResposta) assert.ok(c.porQueNao);
});

test('tokens: piso para o modelo de raciocínio não devolver vazio', () => {
  assert.equal(tokensParaCompor(160), 400);
  assert.equal(tokensParaCompor(2000), 1200);
});

test('conformidade: dinheiro e carência que o agente não tem escritos são barrados', () => {
  const sem = { ...ANA, proibido: [] };
  assert.equal(aplicarFreios('O plano custa R$ 289,90 por mês.', sem).situacao, 'bloqueado');
  assert.equal(aplicarFreios('Fica uns 300 reais.', sem).situacao, 'bloqueado');
  assert.equal(aplicarFreios('E cobre tudo sem carência!', sem).situacao, 'bloqueado');
  // O que o cliente escreveu, o agente pode repetir.
  const comPreco = { ...sem, contexto: ANA.contexto + ' Planos a partir de R$ 199 por mês.' };
  assert.equal(aplicarFreios('Os planos começam em R$ 199 por mês.', comPreco).situacao, 'pronto');
  assert.equal(aplicarFreios('Quanto à carência, o especialista explica na ligação.', sem).situacao, 'pronto');
});

test('dado sensível: RG, dados bancários e PERGUNTA de saúde; mencionar sem perguntar passa', () => {
  const sem = { ...ANA, proibido: [] };
  for (const t of ['Me manda o RG?', 'Pode me passar seus dados bancários?', 'Você tem alguma doença preexistente?',
                   'Já fez alguma cirurgia? Qual seu peso e altura?']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'bloqueado', t);
  }
  assert.equal(aplicarFreios('Não perguntamos sobre doenças por aqui. Quer falar com o especialista?', sem).situacao, 'pronto');
  assert.equal(aplicarFreios('Para quantas pessoas seria o plano?', sem).situacao, 'pronto');
});

test('marca escrita sem colchetes também é marca: não sai para a pessoa', () => {
  assert.equal(aplicarFreios('ESCALAR', ANA).situacao, 'escalar');
  assert.equal(aplicarFreios(' sair. ', ANA).situacao, 'escalar');
  assert.equal(aplicarFreios('Vou escalar isso para a equipe.', ANA).situacao, 'pronto');
});

test('e-mail: o assunto em Markdown vira a linha que o adapter lê', () => {
  assert.equal(normalizarSaida('**Assunto: Seu plano**\n\nOi, Marina!', 'email'), 'Assunto: Seu plano\n\nOi, Marina!');
  assert.equal(normalizarSaida('## Assunto: Re: Proposta\n\nOi', 'email'), 'Assunto: Re: Proposta\n\nOi');
  assert.equal(normalizarSaida('**Assunto: X**', 'whatsapp'), '**Assunto: X**', 'só no e-mail');
  const f = aplicarFreios('**Assunto: Seu plano**\n\nOi, Marina! Podemos conversar?', { ...ANA, canal: 'email' });
  assert.ok(f.situacao === 'pronto' && f.texto.startsWith('Assunto: Seu plano\n'));
});

test('o que do contato vai ao modelo: nem documento, nem saúde, nem CPF disfarçado — e cidade vai', () => {
  const m = { cidade: 'Rio Preto', cpf: '123.456.789-09', Documento: 'x', 'doença': 'diabetes', CID: 'E11',
    'data de nascimento': '01/01/1980', plano_atual: 'Amil', obs: '12345678909', idade: 42, peso_kg: '80' };
  assert.deepEqual(metadadosParaOModelo(m).map(([k]) => k), ['cidade', 'plano_atual']);
  const p = montarPedido({ ...ANA, metadados: m });
  assert.doesNotMatch(p.mensagem, /diabetes|E11|123\.456/);
  assert.match(p.mensagem, /- cidade: Rio Preto/);
});

test('o nome da campanha vai marcado como interno', () => {
  assert.match(montarPedido(ANA).mensagem, /^Campanha \(nome interno, não cite para a pessoa\): Resgate Outubro\./);
});
