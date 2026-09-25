# Resumo para quem decide

Este arquivo existe para você **mudar as coisas sem ter que ler código**. Ele diz, em linguagem
direta, o que o motor faz, que decisões estão embutidas nele, e **onde mexer** em cada uma.

Os dois arquivos vizinhos têm outro público: o `CLAUDE.md` são as regras para quem programa, e o
`DECISOES.md` é o histórico com o porquê de cada escolha. Aqui é o mapa dos botões.

---

## O motor em cinco linhas

1. Contatos entram por importação de planilha (ou, no futuro, pelo CRM).
2. Você inscreve contatos numa **campanha**. A campanha roda um **flow** — a sequência de mensagens.
3. Um worker acorda de tempos em tempos e pergunta: *quem está vencido agora?*
4. Para cada um, ele escolhe o canal, o endereço e o remetente, e cria a mensagem.
5. O que o mundo responde volta como evento, e os fatos importantes vão para o CRM.

**Não é um disparador.** Ninguém aperta "enviar para essa lista". O estado vive em cada contato, e a
execução é o worker acordando. Isso é o que permite cadência de semanas sem nada ficar aberto.

---

## O que está ligado hoje

| | Estado |
|---|---|
| Schema, invariantes, multi-tenant | pronto e aplicado |
| Importar contatos, inscrever, painel, supressão | pronto |
| Adapters de canal (WhatsApp, e-mail, SMS) | prontos, **sem credencial real** |
| Motor rodando | **em shadow mode** — faz tudo e não envia |
| Fatos para o CRM | são **produzidos e enfileirados**; nada os entrega ainda |
| Backfill do sistema antigo | não começou |

**Shadow mode** quer dizer: o motor percorre o caminho inteiro — escolhe canal, escolhe remetente,
reserva cota, compõe o texto — e grava a mensagem como `simulado` em vez de enviar. É o modo que
permite conferir tudo antes de a primeira mensagem sair.

---

## Onde mudar o quê

### Regras de cadência e conteúdo

| Quero mudar | Onde |
|---|---|
| Criar uma campanha do catálogo | Hub → um dos modelos prontos. Vem com tipo, base legal, canais e cadência |
| Criar uma campanha sua | Hub → **Campanha em branco**. Você escreve o tipo, a base legal e os canais, e escolhe uma cadência sua |
| O texto das mensagens e o intervalo entre elas | Tela **Cadências**. **Editar não altera o que existe, de propósito** — salvar publica a *versão seguinte*, e quem já está em cadência termina na versão em que entrou |
| Fazer uma campanha passar a usar a versão nova | Na própria tela da cadência, campanha por campanha. Publicar **não** troca ninguém sozinho: a versão nova pode ter deixado de tocar um canal que a campanha habilita, e cada troca é conferida à parte |
| Quais canais uma campanha usa | Campo `canais_habilitados` da campanha |
| Qual cadência a campanha roda | Tela da campanha, seção **Cadência**. Ela **recusa** a cadência que não compartilha canal nenhum com a campanha |
| Quem responde quando o contato responde | Tela da campanha, seção **Quem responde** — um agente por canal |
| Quantas mensagens por dia cada remetente manda | `quota_diaria` do remetente, na tela do canal |

**As variáveis do texto.** `{{nome}}` e as chaves que vieram na importação viram o valor do
contato. Chave sem valor é **apagada** — o texto sai "Olá ,". A tela de cadência lista, antes de
publicar, quais chaves a sua base realmente tem e com quantos contatos, e acusa a chave que o texto
pede e ninguém tem.

### Parar

Tudo o que começa, para. Três freios, de alcances diferentes:

| Quero parar | Onde | Alcance |
|---|---|---|
| A campanha inteira | Tela da campanha, **Desligar a campanha** | Nada novo é criado. A mensagem que já estava na fila **não é cancelada** — fica segura, porque religar precisa poder recriá-la |
| Só algumas pessoas | Tela da campanha, **Pausar as inscrições** | O relógio de cada uma fica onde estava; retomar continua de onde parou |
| Um chip ou inbox | Tela do canal, **Tirar do pool** | Sai das escolhas futuras **e** as mensagens pendentes que o usavam são passadas para outra conta |

Encerrar uma inscrição à mão não existe, e não por esquecimento: encerramento é fato do motor
(resposta, fim dos passos, supressão), e o banco recusa a escrita que tentar inventá-lo.

### Quem nunca recebe

| Quero mudar | Onde |
|---|---|
| Suprimir uma pessoa ou um endereço | Tela de Supressão |
| Quais palavras numa resposta viram opt-out | Tabela `opt_out_termos` — uma linha por termo, com uma `nota` explicando por que ele está lá |
| Se bounce e denúncia suprimem | Sim, e de formas diferentes — ver abaixo |

**A supressão é definitiva.** Entrar nela não tem volta pela tela, de propósito: é a lista de quem
pediu para não ser incomodado, e ela vale acima de qualquer regra de campanha.

#### Como o motor entende um "pare"

Quando alguém responde, o motor lê o texto e procura pedidos de saída. A parte que importa você
saber, porque é contraintuitiva:

**Termos ambíguos só contam com contexto.** Em plano de saúde, *"quero sair do meu plano"* é alguém
querendo trocar de operadora — o melhor lead que existe. *"Não quero individual, quero empresarial"*
é uma resposta de compra. Suprimir essas pessoas seria perder a venda e fazer o oposto do que elas
pediram.

Então `sair`, `não quero`, `descartar` e `tira` **só suprimem** quando vêm seguidos de algo sobre
receber mensagem: "sair da **lista**", "não quero **receber**". Já `pare`, `descadastrar`,
`não perturbe` e `spam` valem sozinhos, porque não têm outra leitura.

O raciocínio por trás: **errar para mais é irreversível, errar para menos se conserta.** Se alguém
pediu para sair de um jeito que o motor não reconheceu, você suprime pela tela em dez segundos. Se
o motor suprimir um cliente por engano, ele está perdido para sempre.

Para mudar: a tabela `opt_out_termos`. Cada linha tem `termo`, `exige_uma_de` (as palavras de
contexto — vazio quer dizer "vale sozinho") e `nota`, dizendo por que está assim.

**Um buraco que você precisa saber:** responder **PARE a um SMS não é detectado**, porque o
provedor de SMS não tem webhook de entrada — a resposta não chega ao motor de jeito nenhum. É o
caso clássico de opt-out no Brasil, e hoje ele não existe aqui.

#### Devolução e denúncia

São coisas diferentes e o motor trata diferente, porque o CRM recebe fatos diferentes:

| O que aconteceu | O que o motor faz | O que o CRM ouve |
|---|---|---|
| A pessoa marcou como **spam** | suprime a **pessoa**, em todo canal | "pediu para sair" |
| O e-mail **não existe** (devolução permanente) | suprime **só aquele endereço** | "endereço inválido" |
| Caixa cheia (devolução temporária) | **nada** | nada |

A diferença importa: dizer ao CRM que alguém "pediu para sair" quando o que houve foi uma caixa
inexistente é registrar uma decisão que a pessoa nunca tomou — e o comercial lê isso como recusa.

**Quando o provedor não diz se a devolução foi definitiva, o motor trata como temporária.** É
deliberado: suprimir um endereço bom não tem volta; insistir num endereço morto custa uma tentativa.

### O que o CRM fica sabendo

O contrato é **estreito** por decisão: o motor só escreve quatro fatos, e nunca sobrescreve um campo
do qual o CRM é dono.

| Fato | Quando |
|---|---|
| `respondido` | a pessoa respondeu em qualquer canal |
| `opt_out` | a pessoa entrou na supressão |
| `campanha_concluida` | a cadência terminou |
| `identidade_invalida` | o provedor disse que o endereço não existe |

**Mudar essa lista é decisão de produto, não detalhe técnico.** Alargá-la é o começo de o motor
brigar com o CRM por quem manda em cada campo.

### Ritmo e tentativas

| Quero mudar | Onde | Hoje |
|---|---|---|
| De quanto em quanto tempo o worker acorda | Agendamento do motor (`LIGAR.md` §2.4) | a definir ao ligar |
| Quantas vezes um writeback tenta antes de desistir | `registrar_resultado_writeback` | 8 tentativas, espera dobrando até 6h |
| A partir de quantas horas a tela acusa dreno parado | `situacao_do_writeback.ts` | 6 horas |
| Quanto tempo uma mensagem fica reservada por um worker | "lease" das funções de despacho | 5 minutos |

---

## Quando alguém responde

A resposta aparece na tela **Respostas**, com o texto, a mensagem que a provocou e a data. É leitura:
não há "lida" nem "atribuída" — **quem responde é você, no aplicativo do canal**. A tela existe para
você saber que há o que responder.

Duas coisas que ela marca e valem a atenção:

- **"suprimido"** — a resposta foi um pedido de saída, o motor já suprimiu a pessoa, e **não é para
  ligar de volta**. A supressão é definitiva.
- **resposta sem texto** — a pessoa respondeu com áudio, imagem ou anexo, e o provedor não mandou
  nada legível. A tela diz isso em vez de inventar um texto; abra a conversa no aplicativo.

Responder **encerra a cadência** da pessoa em todas as campanhas, sempre. Isso é uma das quatro
garantias do motor, não uma configuração.

---

## Os agentes ainda não respondem

A tela da campanha deixa escolher **quem responde** em cada canal, e a escolha fica gravada — mas
**nada no motor a lê**. Quando o contato responde, a cadência é encerrada (é a invariante 4) e a
conversa não continua sozinha. Não há adapter, função ou worker que consulte o agente.

Isso está escrito na própria tela, de propósito: oferecer a escolha e deixar você supor que ela
produz efeito seria o pior jeito de descobrir — por um lead sem resposta.

O laço de conversa é uma decisão que ainda não foi tomada, e não é pequena: a resposta de um agente
não cabe na tabela de mensagens, cuja chave é "uma mensagem por passo da cadência". Quando for a
hora, é um capítulo próprio.

---

## Três coisas que parecem defeito e não são

**1. A fila de writeback só cresce.** É o esperado hoje: os fatos são produzidos, mas o adapter do
CRM ainda não existe. Nada se perde — cada fato está gravado e datado, e sai na ordem quando o
caminho existir. A tela de Writeback distingue isso de "o dreno parou", e é por isso que ela não
pinta esse estado de vermelho.

**2. O motor roda e não envia nada.** É o shadow mode. A tela da campanha mostra o que teria sido
enviado, inclusive o texto composto.

**3. Uma campanha pode "concluir" sem ter mandado mensagem.** Acontece quando ninguém tinha endereço
no canal dos passos. Por isso toda inscrição em lote tem **prévia**: ela diz, antes de gravar, quem
ficaria de fora e por quê.

---

## O link de acesso volta para o localhost — **conferido, e a causa é esta**

Não é mais suspeita. Os registros de autenticação do projeto guardam as duas tentativas
(24/09 às 02:30 e às 17:33), e nas duas o endereço de retorno resolvido pelo Supabase foi:

```
"mail_type": "magic_link", "mail_to": "admin@grupoafx.com.br"
"referer":   "http://localhost:3000"
```

Esse `http://localhost:3000` **não pode ter saído do app**: em desenvolvimento o app serve na
porta 5173, e em produção ele é `https://`. `http://localhost:3000` é, exatamente, o Site URL
que o Supabase traz de fábrica.

Ou seja: o app pediu o endereço certo, o Supabase **descartou o pedido em silêncio** — porque
ele só honra o endereço de retorno se estiver na lista de permitidos — e caiu no Site URL, que
nunca foi configurado. As duas entradas do login deram certo (`303` e `Login` no registro); o
que está errado é só para onde elas levam.

**Onde arrumar:** Supabase ▸ Authentication ▸ URL Configuration.

| Campo | Valor |
|---|---|
| Site URL | `https://app-eight-snowy-54.vercel.app` |
| Redirect URLs | `https://app-eight-snowy-54.vercel.app/**` |
| | `https://*-afinix.vercel.app/**` *(o endereço próprio de cada deploy)* |
| | `http://localhost:5173/**` *(desenvolvimento local)* |

A segunda linha não é zelo: cada deploy da Vercel ganha também um endereço próprio
(`app-gyrlc8ktj-afinix.vercel.app` é o de agora). Abrir o app por um desses e não tê-lo na lista
reproduz o mesmo defeito com a configuração "certa" — e aí o sintoma volta sem explicação.

**Se ainda assim continuar errado**, o segundo suspeito é o texto do e-mail: em
Authentication ▸ Email Templates ▸ Magic Link, o link precisa usar `{{ .RedirectTo }}`. Se estiver
escrito `{{ .SiteURL }}`, ele ignora o pedido do app por construção.

**Como conferir depois de mexer, sem depender da caixa de entrada** — é o D44 outra vez, uma
configuração manual cujo erro é indistinguível do funcionamento normal. Peça um link novo e leia
o registro: em Supabase ▸ Logs ▸ Auth, a linha do `mail.send` mais recente. O campo `referer` da
requisição `/otp` ao lado dela é o endereço que o Supabase de fato vai usar. Se ele mudou de
`http://localhost:3000` para o endereço do app, está resolvido — e isso se sabe **antes** de
abrir o e-mail.

E do lado de cá: **a tela de entrada mostra o endereço para onde pediu que o link voltasse**,
logo depois de enviá-lo. O que o app pede está visível na tela; o que o Supabase faz com o pedido
está visível no registro. A diferença entre os dois é o defeito.

## O que ainda depende de você

1. **Ligar o motor** — `LIGAR.md`: criar o cliente, guardar a chave, **conferir antes de agendar**,
   cadastrar um remetente. Nenhum desses passos eu consigo fazer: meu acesso ao banco é de leitura.
2. **O projeto legado** — para o adapter do CRM (mapeamento de campos do Pipefy) e para o backfill.
3. **A política de rede do ambiente** — enquanto bloquear o Supabase, não consigo abrir as telas no
   navegador para conferir o que construí.

---

## Como saber que está tudo de pé

```bash
tests/run.sh      # a bateria inteira: SQL, TypeScript e checagem de tipos
demo/gerar.sh     # roda o motor num cenário de 125 horas e confere o resultado
```

Teste vermelho é bloqueio, não aviso. Toda mudança de schema roda a bateria antes de entrar.
