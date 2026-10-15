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

// ---------------------------------------------------------------------------
// D76, revisão: os freios nos dois sentidos — o que tem de barrar e o que não pode
// ---------------------------------------------------------------------------

test('dinheiro: valor a valor contra o que o cliente escreveu, e preço sem "R$" também conta', () => {
  const comPreco = { ...ANA, proibido: [], contexto: ANA.contexto + ' Planos a partir de R$ 189,90 por mês.' };
  assert.equal(aplicarFreios('Os planos começam em R$ 189,90.', comPreco).situacao, 'pronto');
  assert.equal(aplicarFreios('O familiar para quatro sai por R$ 749,00 por mês.', comPreco).situacao, 'bloqueado');
  for (const t of ['A mensalidade fica em 289,90.', 'A partir de 189/mês.', 'Fica perto de 1 mil reais.', 'Uns mil reais por mês.']) {
    assert.equal(aplicarFreios(t, { ...ANA, proibido: [] }).situacao, 'bloqueado', t);
  }
  // A proibição escrita no roteiro não libera o valor: o roteiro do agente novo não conta.
  const proibindo = { ...ANA, proibido: [], instrucoes: ANA.instrucoes + ' Nunca cite valores como R$ 300.' };
  assert.equal(aplicarFreios('O plano sai por R$ 300 por mês.', proibindo).situacao, 'bloqueado');
  // Número que não é dinheiro passa.
  assert.equal(aplicarFreios('A ligação leva 15 minutos. Pode ser às 14h?', { ...ANA, proibido: [] }).situacao, 'pronto');
  // O valor que está nas informações do contato (renovação) pode ser repetido.
  assert.equal(aplicarFreios('Hoje você paga R$ 412,30.', { ...ANA, proibido: [], metadados: { mensalidade: 'R$ 412,30' } }).situacao, 'pronto');
});

test('carência: só a que o cliente AFIRMOU no contexto, nunca a da proibição', () => {
  const sem = { ...ANA, proibido: [] };
  const proibindo = { ...sem, instrucoes: sem.instrucoes + ' Nunca diga que o plano é sem carência.' };
  assert.equal(aplicarFreios('Ótima notícia: nosso plano é sem carência!', proibindo).situacao, 'bloqueado');
  assert.equal(aplicarFreios('A carência de 30 dias vale para consultas.', sem).situacao, 'bloqueado');
  const afirmando = { ...sem, contexto: sem.contexto + '\nPlanos empresariais acima de 30 vidas são sem carência.' };
  assert.equal(aplicarFreios('Para empresas acima de 30 vidas, o plano é sem carência.', afirmando).situacao, 'pronto');
  const negando = { ...sem, contexto: sem.contexto + '\nNão temos plano sem carência.' };
  assert.equal(aplicarFreios('Temos plano sem carência!', negando).situacao, 'bloqueado');
});

test('dado sensível: barra o pedido, não a frase que tranquiliza', () => {
  const sem = { ...ANA, proibido: [] };
  for (const t of ['Pode me mandar o número do seu cartão?', 'Me informa os dados do seu cartão.', 'Qual o seu CPF?',
                   'Preciso do seu RG para seguir.']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'bloqueado', t);
  }
  for (const t of ['Entendo sua preocupação. Por aqui não vamos pedir senha nem dado de cartão.',
                   'Fique tranquila: nunca pedimos CPF por mensagem.', 'Não pedimos CPF nem dados bancários.',
                   'Aceitamos pagamento no cartão de crédito.']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'pronto', t);
  }
});

test('saúde: barra a pergunta sobre a pessoa, não a pergunta sobre a cobertura', () => {
  const sem = { ...ANA, proibido: [] };
  for (const t of ['Alguém da família tem algum problema de saúde?', 'Você ou seus dependentes têm alguma condição de saúde?',
                   'Você está grávida?', 'Você toma algum remédio controlado?', 'Você fuma? Tem pressão alta ou diabetes?',
                   'Você tem alguma doença preexistente?']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'bloqueado', t);
  }
  for (const t of ['Você precisa de cobertura internacional?', 'Prefere um plano com ou sem coparticipação em internações?',
                   'O plano inclui atendimento para gestante?', 'Quer cobertura para tratamentos odontológicos?',
                   'Enfermaria ou apartamento nas internações?', 'Cid, qual o melhor horário para conversarmos?']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'pronto', t);
  }
});

test('saída: o agente que CONFIRMA uma remoção escala — ninguém a gravou', () => {
  // A cópia da Ana tem "confirme em uma frase e encerre" na instrução: o freio é que segura.
  const antiga = { ...ANA, objetivo: null, instrucoes: 'Se a pessoa pedir para não ser mais contatada, confirme em uma frase e encerre.' };
  for (const t of ['Certo, não vamos mais te contatar.', 'Tudo bem, removi seu número da nossa lista.',
                   'Você não receberá mais mensagens nossas.', 'Pronto, você foi descadastrada.']) {
    const f = aplicarFreios(t, antiga);
    assert.equal(f.situacao, 'escalar', t);
    assert.match((f as { motivo: string }).motivo, /Supressão/);
  }
  assert.equal(aplicarFreios('Sem problema! Se mudar de ideia, é só chamar.', antiga).situacao, 'pronto');
});

test('metadados: pelo nome e pelo valor — texto livre de anotação não vai, celular não some', () => {
  const m = {
    observacao: 'Paciente diabético, faz hemodiálise', comorbidades: 'x', condicao_medica: 'y', cid10: 'E11',
    gestante: 'sim', 'dt nasc': '01/01/1980', carteirinha: '123', rendimento: '5000', obs: 'CPF 123.456.789-00',
    telefone2: '11999999999', nota_interna: 'cliente difícil',
    cidade: 'Rio Preto', empresa: 'ACME', cargo: 'RH', plano: 'Amil', operadora: 'Amil', vidas: '4',
    idade_titular: '42', cnpj: '12.345.678/0001-90', comentario_livre: 'qualquer',
  };
  assert.deepEqual(metadadosParaOModelo(m).map(([k]) => k).sort(),
    ['cargo', 'cidade', 'cnpj', 'empresa', 'idade_titular', 'operadora', 'plano', 'telefone2', 'vidas']);
});

// ---------------------------------------------------------------------------
// D76, segunda revisão: as frases que a revisão adversarial achou, nos dois sentidos
// ---------------------------------------------------------------------------

test('dado sensível: pedir de qualquer jeito é barrado; tranquilizar e falar de pagamento, não', () => {
  const sem = { ...ANA, proibido: [] };
  for (const t of ['Para gerar a cotação, vou precisar do seu CPF e da data de nascimento.',
                   'Pode me enviar o seu CPF por aqui mesmo.', 'Fico no aguardo do seu CPF para dar andamento.',
                   'Sem o CPF não consigo cotar, me passa?', 'Se não for incômodo, me passa seu CPF?',
                   'Não pedimos CPF, só preciso do seu RG.', 'Me passa a senha do aplicativo?',
                   'Qual o número da sua conta?', 'Me manda sua CNH, por favor.']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'bloqueado', t);
  }
  for (const t of ['O especialista te passa as opções de pagamento no cartão de crédito.',
                   'A operadora envia a senha do aplicativo por e-mail depois da assinatura.',
                   'O pagamento pode ser no boleto ou no cartão de crédito, qual você prefere?',
                   'Conseguiu acessar o aplicativo com a senha que a operadora mandou?',
                   'Fique tranquila: nunca vamos pedir sua senha por mensagem.']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'pronto', t);
  }
});

test('saúde: "plano", "carência" e "rede" na frase não liberam a pergunta sobre a pessoa', () => {
  const sem = { ...ANA, proibido: [] };
  for (const t of ['Para cotar o plano, alguém tem doença preexistente?',
                   'Você toma algum medicamento contínuo que precise de cobertura?',
                   'Alguém da família faz algum tratamento que o plano precise cobrir?',
                   'Alguém já fez cirurgia ou está grávida, para eu ver a carência?',
                   'Me conta se alguém da família tem doença preexistente.',
                   'Preciso saber se você toma algum remédio controlado.']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'bloqueado', t);
  }
  for (const t of ['Se alguém precisar ficar internado, prefere quarto individual?',
                   'Você teria interesse em desconto em farmácia e remédios?']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'pronto', t);
  }
});

test('saída: as confirmações de remoção que o português usa de fato escalam', () => {
  const antiga = { ...ANA, objetivo: null, instrucoes: 'Se a pessoa pedir para não ser mais contatada, confirme em uma frase e encerre.' };
  for (const t of ['Tudo bem, não vamos mais entrar em contato.', 'Entendido, não entraremos mais em contato com você.',
                   'Combinado, não enviaremos mais mensagens.', 'Pronto, tirei seu número da nossa lista.',
                   'Certo, excluímos seu contato da nossa base.', 'Você não será mais contatada.',
                   'Vou parar de te mandar mensagens.']) {
    assert.equal(aplicarFreios(t, antiga).situacao, 'escalar', t);
  }
});

test('carência: as formas naturais são barradas; a condição que o cliente afirmou, em parágrafo único, passa', () => {
  const sem = { ...ANA, proibido: [] };
  for (const t of ['Esse plano não tem carência para consultas.', 'E o melhor: sem nenhuma carência!',
                   'A carência é de 30 dias para exames.', 'Consultas têm só 30 dias de carência.',
                   'Urgência tem carência de 24 horas.', 'Você não precisa cumprir carência.',
                   'Temos redução de carência para quem vem de outro plano.']) {
    assert.equal(aplicarFreios(t, sem).situacao, 'bloqueado', t);
  }
  const paragrafo = { ...sem, contexto: 'Falamos em nome da Afinix Corretora. Planos empresariais a partir de 2 vidas '
    + 'são sem carência. Não trabalhamos com plano individual.' };
  assert.equal(aplicarFreios('Para empresas a partir de 2 vidas, o plano é sem carência.', paragrafo).situacao, 'pronto');
  // A mesma fonte não libera uma carência DIFERENTE da afirmada.
  assert.equal(aplicarFreios('A carência é de 30 dias.', paragrafo).situacao, 'bloqueado');
  const dias = { ...sem, contexto: sem.contexto + ' Consultas com carência de 30 dias.' };
  assert.equal(aplicarFreios('Para consultas, a carência é de 30 dias.', dias).situacao, 'pronto');
  assert.equal(aplicarFreios('Para exames, a carência é de 24 horas.', dias).situacao, 'bloqueado');
});

test('dinheiro: número que não é preço não libera valor; "2 mil reais" é 2000; decimal com ponto do CRM conta', () => {
  const sem = { ...ANA, proibido: [] };
  const empresas = { ...sem, contexto: 'Falamos em nome da Afinix Corretora, há 20 anos no mercado e com mais de 500 empresas atendidas.' };
  assert.equal(aplicarFreios('O plano individual sai por R$ 500 por mês.', empresas).situacao, 'bloqueado');
  assert.equal(aplicarFreios('Fica uns 500 reais.', empresas).situacao, 'bloqueado');
  // Metadado que não foi ao modelo não libera valor.
  assert.equal(aplicarFreios('Hoje fica em R$ 5.000.', { ...sem, metadados: { renda: '5000' } }).situacao, 'bloqueado');
  assert.equal(aplicarFreios('Sai por R$ 1.980.', { ...sem, metadados: { nascimento: '01/01/1980' } }).situacao, 'bloqueado');
  // A proibição da instrução antiga não libera o valor que ela proíbe.
  const antiga = { ...sem, objetivo: null, instrucoes: 'Nunca cite valores como R$ 300. Não ofereça o plano de R$ 199.' };
  assert.equal(aplicarFreios('O plano sai por R$ 300 por mês.', antiga).situacao, 'bloqueado');
  assert.equal(aplicarFreios('Temos o plano de R$ 199.', antiga).situacao, 'bloqueado');
  const doisMil = { ...sem, contexto: sem.contexto + ' Planos empresariais a partir de R$ 2.000 por mês.' };
  assert.equal(aplicarFreios('Os empresariais começam em 2 mil reais por mês.', doisMil).situacao, 'pronto');
  const milEMeio = { ...sem, contexto: sem.contexto + ' O familiar sai por R$ 1.500.' };
  assert.equal(aplicarFreios('O familiar fica em 1,5 mil reais.', milEMeio).situacao, 'pronto');
  assert.equal(aplicarFreios('Hoje você paga R$ 412,30.', { ...sem, metadados: { mensalidade: '412.30' } }).situacao, 'pronto');
  // Preço sem "R$" numa frase que fala de preço conta como escrito.
  const semCifrao = { ...sem, contexto: sem.contexto + ' Mensalidade a partir de 289 por pessoa.' };
  assert.equal(aplicarFreios('A mensalidade começa em R$ 289.', semCifrao).situacao, 'pronto');
});

test('metadados: CPF sem máscara em coluna de nome neutro, RG e saúde por outros nomes não vão ao modelo', () => {
  const m = { id_cliente: '52998224725', doc: '123', identidade: '12.345.678-9', patologia: 'asma e colesterol alto',
    'histórico médico': 'infarto em 2020', alergias: 'dipirona', celular: '11987654321', cidade: 'Rio Preto' };
  assert.deepEqual(metadadosParaOModelo(m).map(([k]) => k).sort(), ['celular', 'cidade']);
});

test('proibido com elemento que não é texto não derruba o freio', () => {
  const f = aplicarFreios('Oi, Marina! Podemos conversar?', { ...ANA, proibido: [null as unknown as string, 'garantimos'] });
  assert.equal(f.situacao, 'pronto');
});
