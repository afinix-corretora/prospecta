# Mapa de `status` legado → modelo novo

> Pré-requisito do backfill da Fase 2. Sem ele o backfill inventa estado.
> Quatro itens precisam de decisão humana — estão marcados como **DECISÃO** e listados no fim.

---

## Por que este documento existe

Os três pipelines antigos têm vocabulários de `status` diferentes e incoerentes entre si: 14 valores
em `rescue_leads`, 8 em `blast_leads`, 5 em `broadcast_recipients`. O modelo novo separa o que eles
misturam:

| Fato | Onde vive no modelo novo |
|---|---|
| A inscrição está viva, pausada ou acabou | `enrollments.status` |
| Por que acabou | `enrollments.motivo_encerramento` |
| O que aconteceu com cada disparo | `message_events` (append-only) |
| Quem não pode mais receber nada | `suppression` |
| O que contar ao CRM | `outbox` |

Uma coluna vira quatro lugares. É por isso que o mapa não é linha a linha automático.

---

## O risco que justifica revisar isto antes de rodar

`blast_leads.status = 'discarded'` é gravado por **dois caminhos com significados opostos**:

- `evolution-webhook` grava `discarded` + `source_metadata.discarded_reason = 'opt_out'` quando o
  classificador detecta pedido de saída — e insere em `contact_blacklist` na mesma transação lógica.
- `blast-mark-disregard` e `blast-delete-card` gravam `discarded` **sem** `discarded_reason`, quando
  o operador descarta o lead manualmente.

Mapear `discarded` para um único destino perde a distinção. Se o opt-out virar "descarte
operacional", a pessoa **volta a ser elegível** no motor novo — quebra direta da invariante 2, no
primeiro dia de produção, com registro de que ela pediu para sair.

Regra derivada: **o backfill não lê `discarded` isolado.** Lê o par
(`status`, `source_metadata.discarded_reason`), e trata ausência de metadado pelo lado seguro
(ver DECISÃO 4).

---

## `rescue_leads` → `enrollments`

14 valores. O `CHECK` foi alargado quatro vezes em seis semanas; alguns valores nunca são escritos.

| Status legado | `status` | `motivo_encerramento` | Efeito colateral obrigatório |
|---|---|---|---|
| `pending` | `ativo` | — | `passo_atual = 0`, `next_run_at = now()` |
| `in_progress` | `ativo` | — | `passo_atual = current_step`, `next_run_at = next_scheduled_at` |
| `sent` | `ativo` | — | Idem `in_progress`. Valor legado do `CHECK` inicial. |
| `responded` | `encerrado` | `resposta` | **Vocabulário morto** — está no `CHECK`, nenhuma function escreve. Mapear por segurança, pode não existir linha. |
| `engaged` | `encerrado` | `resposta` | Evento `respondido` em `message_events` a partir de `responded_at` |
| `qualified` | `encerrado` | `mudanca_etapa_crm` | `dispatch-integration` já despachou ao CRM. Não gerar `outbox` — o CRM já sabe. |
| `disqualified` | `encerrado` | `mudanca_etapa_crm` | Idem |
| `blacklisted` | `encerrado` | `supressao` | Linha em `suppression` (ver seção de supressão) |
| `completed` | `encerrado` | `fim_dos_passos` | — |
| `failed` | `encerrado` | `falha_permanente` | — |
| `paused` | `pausado` | — | `next_run_at = NULL` |
| `waiting_cycle` | **DECISÃO 2** | | |
| `reengaging` | **DECISÃO 1** | | |
| `cancelled` | `encerrado` | **DECISÃO 3** | Falta valor no enum |

## `blast_leads` → `enrollments`

8 valores. Mistura estado de entrega com desfecho comercial, e mantém `wa_status`/`sms_status` em
paralelo na mesma linha — esses dois viram `messages` + `message_events`, nunca colunas.

| Status legado | `status` | `motivo_encerramento` | Nota |
|---|---|---|---|
| `pending` | `ativo` | — | |
| `processing` | `ativo` | — | Era o mutex por status; no modelo novo não há estado intermediário — a trava é `FOR UPDATE SKIP LOCKED` |
| `sent` | `encerrado` | `fim_dos_passos` | Blast é disparo único: enviado = cadência terminada |
| `positive` | `encerrado` | `mudanca_etapa_crm` | `blast-create-card` criou card no CRM |
| `discarded` com `discarded_reason = 'opt_out'` | `encerrado` | `supressao` | **+ linha em `suppression`** |
| `discarded` sem `discarded_reason` | `encerrado` | **DECISÃO 3** | Descarte operacional |
| `blacklisted` | `encerrado` | `supressao` | + linha em `suppression` |
| `failed` | `encerrado` | `falha_permanente` | |
| `cancelled` | `encerrado` | **DECISÃO 3** | |

## `broadcast_recipients` → `enrollments`

O mais simples: 5 valores, sem semântica comercial.

| Status legado | `status` | `motivo_encerramento` |
|---|---|---|
| `pending` | `ativo` | — |
| `processing` | `ativo` | — |
| `sent` | `encerrado` | `fim_dos_passos` |
| `completed` | `encerrado` | `fim_dos_passos` |
| `failed` | `encerrado` | `falha_permanente` |

---

## O que o backfill faz além de mapear status

Mapear a coluna é a parte pequena. O resto:

1. **`contact_blacklist` → `suppression`, primeiro de tudo.** Antes de qualquer enrollment. O
   trigger `messages_respeita_supressao` só protege se a supressão já existir. `contact_blacklist`
   é indexada por telefone normalizado, então vira `suppression (canal='whatsapp', valor_norm=...)`.
   Suprimir a **pessoa** (`contact_id`, `canal IS NULL`) é mais forte e provavelmente mais correto,
   já que quem pediu para sair pediu para sair de tudo — ver DECISÃO 4.
2. **Identidades com dedup.** `contacts.phone_number` do modelo antigo vira `contact_identities`.
   O índice único `(canal, valor_norm)` recusa duplicata: a ingestão normaliza antes de inserir, e
   colisão entre contatos diferentes precisa de resolução, não de `ON CONFLICT DO NOTHING`.
3. **Logs → `messages` + `message_events`.** `rescue_message_logs` e `blast_message_logs` viram
   `messages` (uma por `(enrollment, step)`, respeitando a chave única) e os carimbos de tempo viram
   eventos append-only. `status` de mensagem não é copiado: é derivado dos eventos.
4. **`responded_at`, `last_sent_at`, `blacklisted_at`** viram eventos com `ocorrido_em` preservado.
   Backfill que grava `now()` em tudo destrói a linha do tempo e inviabiliza a comparação da Fase 3.

Ordem obrigatória: `suppression` → `contacts`/`contact_identities` → `campaigns`/`flows` →
`enrollments` → `messages` → `message_events`.

---

## Decisões que precisam de você

### DECISÃO 1 — `reengaging` (camada 2 do resgate)

`rescue-reengage` implementa uma segunda camada: o lead que respondeu e esfriou recebe um lembrete,
com `layer2_step` e `layer2_last_sent_at` próprios. O modelo novo não tem camadas — tem enrollments.

- **(a) Recomendado — vira enrollment novo** numa campanha "reengajamento", com flow próprio. Fica
  explícito, contável e reutilizável para qualquer campanha, não só resgate.
- (b) Vira passo adicional no mesmo flow. Mais barato de migrar, mas reintroduz a camada dentro do
  enrollment e some com a distinção no relatório.

### DECISÃO 2 — `waiting_cycle` (ciclo de recomeço)

Campanha com `cycle_enabled` reinicia o lead após `cycle_interval_days`, zerando `current_step`.

- **(a) Recomendado — encerra e reinscreve.** `encerrado` / `fim_dos_passos`, mais um enrollment novo
  com `next_run_at = next_scheduled_at`. Mantém a regra "um enrollment é uma passada pelo flow",
  preserva o histórico de cada ciclo e funciona com o índice único de enrollment ativo por campanha.
- (b) Mantém `ativo` com `next_run_at` no futuro e `passo_atual = 0`. Migra em uma linha, mas
  colapsa todos os ciclos num registro só.

### DECISÃO 3 — Falta um motivo de encerramento operacional

`cancelled` (nos três pipelines) e o `discarded` manual do blast não têm destino honesto no enum
atual: não foram resposta, nem mudança de etapa, nem fim dos passos, nem supressão, nem falha.

Forçá-los em `falha_permanente` mente no relatório — vira "o motor falhou" quando foi decisão de
alguém. Recomendo **adicionar `cancelado_operacional`** ao enum `motivo_encerramento`, em migration
própria antes do backfill. É aditivo e barato agora; depois do backfill, caro.

### DECISÃO 4 — Alcance da supressão migrada

Hoje a blacklist é só telefone. Ao migrar:

- **(a) Recomendado — suprime a pessoa** (`contact_id`, todos os canais). Quem pediu para sair do
  WhatsApp não autorizou e-mail frio; o motor novo é multicanal e a lista é descrita no `CLAUDE.md`
  como "global". Mais restritivo, e o erro cai para o lado de não incomodar.
- (b) Suprime só a identidade de WhatsApp. Fiel ao dado antigo, mas abre e-mail e SMS para quem já
  pediu para sair.

A mesma escolha vale para `discarded` sem `discarded_reason`: tratar como opt-out (seguro, pode
suprimir alguém que só foi descartado por engano) ou como descarte operacional (arriscado, pode
remessagear quem pediu para sair). **Recomendo o lado seguro** — um lead a menos custa menos que uma
reclamação de LGPD e um remetente queimado.

---

## Validação do backfill

Rodar depois do backfill, antes de qualquer envio. Nenhuma pode devolver linha:

```sql
-- 1. Ninguém da blacklist antiga ficou de fora da supressão.
SELECT b.phone_number FROM legado.contact_blacklist b
 WHERE NOT EXISTS (
   SELECT 1 FROM suppression s
   WHERE s.valor_norm = regexp_replace(b.phone_number,'\D','','g')
      OR s.contact_id = b.contact_id);

-- 2. Nenhum enrollment ativo aponta para contato suprimido.
SELECT e.id FROM enrollments e
 WHERE e.status = 'ativo'
   AND EXISTS (SELECT 1 FROM suppression s WHERE s.contact_id = e.contact_id);

-- 3. Nenhum encerrado sem motivo, nenhum ativo com motivo.
--    (o CHECK do schema já recusa, mas a query prova que nada foi contornado)
SELECT id FROM enrollments
 WHERE (status = 'encerrado') <> (motivo_encerramento IS NOT NULL);

-- 4. Nenhum status legado ficou sem mapeamento.
SELECT DISTINCT status FROM legado.rescue_leads
 WHERE status NOT IN ('pending','in_progress','sent','responded','engaged','qualified',
   'disqualified','blacklisted','completed','failed','paused','waiting_cycle',
   'reengaging','cancelled');

-- 5. A linha do tempo sobreviveu: nenhum evento carimbado no momento do backfill.
SELECT count(*) FROM message_events
 WHERE ocorrido_em::date = current_date AND tipo <> 'enfileirado';
```
