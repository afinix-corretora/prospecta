# Proposta: o laço de conversa

**Para que serve este documento.** O produto tem agentes cadastrados, atribuíveis por canal, e
nenhuma parte do motor os consulta. Fazer com que eles respondam de verdade não é "mais uma tela":
encosta em três garantias do motor e em duas perguntas que são de produto, não de engenharia.

Este arquivo existe para você decidir **sobre papel**. Nada aqui foi construído, nenhuma migration
foi escrita, e nenhuma das opções está começada. É deliberado: a escolha errada aqui só apareceria
meses depois, na forma de uma invariante furada.

> Os outros dois arquivos vizinhos têm outro público: `DECISOES.md` é o histórico do que **foi**
> decidido, e `CLAUDE.md` são as regras para quem programa. Este é o único que fala de algo que
> ainda não existe.

---

## 1. O que existe hoje, conferido linha a linha

| Peça | Estado |
|---|---|
| `agents`, `campaign_agents`, `agente_do_canal` | existem, com RLS e grants |
| Tela para atribuir agente por canal | existe (D54) |
| `agents.ai_credential_id` | nasce **NULL** na cópia do catálogo, e ninguém o lê |
| `limite_trocas`, `escalar_quando` | colunas preenchidas, **zero leitores em código** |
| Texto da resposta da pessoa | gravado em `message_events.payload ->> 'texto'` (D48) |
| Quem lê esse texto | o classificador de opt-out (D48) e a tela de Respostas (D56) |
| Janela de 24h do WhatsApp/Instagram | **só como prosa** — descrição de catálogo e instrução de agente. Nenhuma coluna, nenhum CHECK |

Ou seja: a matéria-prima está toda lá, e não há **um** caminho de código que leve de "a pessoa
respondeu" a "alguém respondeu de volta".

---

## 2. A colisão: três travas que o laço encontra

Não são obstáculos a contornar. São garantias que existem de propósito, e cada uma foi escrita
depois de um defeito real.

### 2.1 A invariante 4 encerra tudo

`encerrar_por_resposta` é um gatilho em `message_events`: qualquer evento `respondido` encerra
**todos** os enrollments daquele contato, em qualquer campanha e canal, com
`motivo_encerramento = 'resposta'`.

Isso é correto e deve continuar: quem respondeu não pode seguir recebendo cadência. Mas significa
que, no instante em que a conversa começa, o enrollment já está `encerrado`.

### 2.2 O gate do D40 cancela o que estiver na fila

`reivindicar_pendentes`, passo 2:

```
IF m.estado_enrollment = 'encerrado'
   AND m.motivo_encerramento IS DISTINCT FROM 'fim_dos_passos' THEN
  UPDATE messages SET status = 'cancelado' ...
```

`resposta` é exatamente um desses motivos. **Uma mensagem de agente criada sobre esse enrollment
seria cancelada pelo despacho.** E o D40 existe justamente para isso: *"encerrar a cadência e mandar
mais um toque é a invariante furada pela borda"*.

O laço de conversa precisa que o despachante distinga **"mais um toque da cadência"** de **"uma
resposta ao que a pessoa disse"**. Essa distinção é o coração do desenho.

### 2.3 A chave de idempotência não tem lugar para a conversa

`messages` tem `UNIQUE (enrollment_id, step_id)` — uma mensagem por passo da cadência. Uma resposta
de agente não tem passo. Não há onde ela caber sem mexer na chave que é a invariante 1.

---

## 3. As quatro perguntas que só você responde

Estas não têm resposta técnica. Cada uma muda o desenho.

**(a) O agente responde sozinho, ou escreve o rascunho para uma pessoa aprovar?**
Autônomo é o que escala. Rascunho é o que não manda besteira para um cliente em nome da corretora.
São produtos diferentes, e o segundo é muito mais barato de construir e de errar.

**(b) Resposta de agente paga quota de remetente?**
A invariante 3 limita quanto cada chip manda por dia. Responder a quem escreveu para você não é
volume de prospecção — mas é mensagem saindo pelo mesmo chip, e o provedor conta igual. Contar a
mais aperta a prospecção; contar a menos fura a invariante 3 pela borda.

**(c) O que acontece quando a janela de 24h fecha?**
Em WhatsApp e Instagram a conversa livre só existe dentro de 24h da última mensagem da pessoa.
Depois disso, ou é template aprovado, ou é silêncio. O schema não sabe nada disso hoje. Se o agente
for autônomo, isso vira uma coluna e uma trava — não uma frase na instrução dele.

**(d) Quanto custa, e quem paga?**
Cada resposta é uma chamada de API de modelo. Com `limite_trocas = 10` e mil leads respondendo, é
conta real. Hoje não há teto por tenant, nem medição.

---

## 4. Três desenhos, e o que cada um custa

### Opção A — Rascunho para pessoa aprovar

O agente compõe, a tela mostra ao lado da resposta (a tela de Respostas do D56 já é o lugar), e
**uma pessoa aprova e manda pelo aplicativo do canal**.

- **Não encosta em nenhuma das três travas.** Nada sai pelo motor, então não há mensagem, não há
  chave, não há gate. A invariante 4 continua absoluta.
- Janela de 24h: problema de quem manda, como já é hoje.
- Quota: não se aplica.
- O que é preciso construir: a chamada ao modelo e um lugar para guardar o rascunho.
- **O que não entrega:** ninguém é atendido às 23h de domingo.

### Opção B — Agente responde pelo motor, na mesma tabela

`messages.step_id` passa a aceitar NULL; a chave única vira parcial
(`WHERE step_id IS NOT NULL`); a idempotência da conversa passa a ser
`(enrollment_id, evento_que_respondeu)`.

- **Mantém um caminho de envio só** — e portanto o gate de supressão, o pool por tipo de campanha e
  o rate limit continuam valendo sem duplicação. É o que as anti-regras pedem.
- **Exige abrir o gate do D40**, que é a parte perigosa: o despacho passa a precisar de um critério
  positivo ("esta mensagem é resposta a um evento") em vez do critério negativo de hoje. Um erro aí
  é a cadência voltando a falar com quem respondeu — o defeito que o D40 existe para impedir.
- Janela de 24h vira coluna e trava de verdade.
- Quota: decisão (b) vira uma linha de código, nos dois sentidos.

### Opção C — Tabela separada de conversa

`conversation_messages`, com despacho próprio.

- Não mexe em `messages`, não mexe no D40.
- **Cria um segundo caminho de envio** — e com ele uma segunda cópia do gate de supressão, do pool e
  do rate limit. É literalmente a anti-regra *"nunca implementar envio que não passe pelo roteador"*,
  e a divergência entre as duas cópias apareceria na forma que o D32 descreve: supressão furada.
- Barato de começar, caro de manter correto.

---

## 5. Recomendação

**Opção A primeiro, opção B depois — e a decisão (a) não precisa ser tomada de uma vez.**

O motivo não é timidez. É que a opção A entrega a parte cara e incerta (o agente compor bem, com a
instrução certa, no tom certo) **sem** tocar em nenhuma garantia do motor. Se o rascunho sair ruim,
o prejuízo é uma pessoa apagando texto na tela. Se um agente autônomo sair ruim, o prejuízo é um
cliente recebendo besteira em nome da corretora — e provavelmente o chip banido.

E a opção A produz exatamente o que falta para decidir a (a) com dado em vez de palpite: algumas
centenas de rascunhos que você leu e julgou. A opção B, depois disso, é uma migration e um critério
no despacho — e aí as perguntas (b), (c) e (d) já terão resposta vinda da prática.

A opção C eu não recomendaria em nenhum cenário: o que ela economiza hoje é o que o D32 cobra
depois.

---

## 6. O que vale construir sob qualquer resposta

Duas coisas, e nenhuma delas depende de você decidir agora:

1. **A credencial de IA precisa chegar ao agente.** `agents.ai_credential_id` nasce NULL na cópia do
   catálogo e nenhuma tela o preenche. Em qualquer opção, um agente sem credencial é um agente que
   não funciona — e hoje isso não aparece em lugar nenhum.
2. **`limite_trocas` e `escalar_quando` precisam de leitor, ou de aviso.** São colunas preenchidas,
   com valores razoáveis, que nenhum código lê. É o `tem_adapter` do D31 esperando: ou passam a
   valer, ou a tela diz que ainda não valem.

---

## 7. O que este documento não decide

Nada sobre backfill, nada sobre o adapter do CRM, e nada sobre ligar o motor — os três seguem
bloqueados pelos motivos de sempre (acesso ao projeto legado, e os passos do `LIGAR.md` que
dependem de segredo real).
