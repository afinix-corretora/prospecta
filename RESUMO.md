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
| Quais palavras numa resposta viram opt-out | *(em construção — será uma lista num só lugar)* |
| Se bounce e denúncia suprimem | *(em construção)* |

**A supressão é definitiva.** Entrar nela não tem volta pela tela, de propósito: é a lista de quem
pediu para não ser incomodado, e ela vale acima de qualquer regra de campanha.

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
