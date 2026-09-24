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
| O texto das mensagens e o intervalo entre elas | Flow novo pela tela. **Editar um flow existente não é possível de propósito** — editar cria uma versão nova, e quem já está em cadência termina na versão em que entrou |
| Quais canais uma campanha usa | Campo `canais_habilitados` da campanha |
| Qual flow a campanha roda | `definir_flow_da_campanha`. Ele **recusa** flow que não compartilha canal nenhum com a campanha |
| Quantas mensagens por dia cada remetente manda | `quota_diaria` do remetente |

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
