# Mapa de `status` legado → modelo novo

> Pré-requisito do backfill da Fase 2. Sem ele o backfill inventa estado.
> As quatro decisões em aberto foram tomadas (D13 em `DECISOES.md`) e o mapa está fechado.
>
> **Este documento é a explicação; a fonte de verdade é `backfill/mapa_status.sql`**, testado em
> `tests/mapa_status.sql` com os 27 valores legados. Divergiu, vale o código — e o teste acusa.

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
(D13.4). `backfill/mapa_status.sql` implementa isso, e `tests/mapa_status.sql` cobre as três
variantes de `discarded`.

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
| `waiting_cycle` | `encerrado` | `fim_dos_passos` | **+ enrollment novo** na mesma campanha, `next_run_at = next_scheduled_at` |
| `reengaging` | `encerrado` | `resposta` | **+ enrollment novo** em campanha de reengajamento (o lead está aqui porque respondeu) |
| `cancelled` | `encerrado` | `cancelado_operacional` | Valor acrescentado ao enum pela migration `20260916140000` |

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
| `discarded` com outro `discarded_reason` | `encerrado` | `cancelado_operacional` | Descarte operacional explícito |
| `discarded` sem `discarded_reason` | `encerrado` | `supressao` | **+ `suppression`** — lado seguro, ver D13.4 |
| `blacklisted` | `encerrado` | `supressao` | + linha em `suppression` |
| `failed` | `encerrado` | `falha_permanente` | |
| `cancelled` | `encerrado` | `cancelado_operacional` | |

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
   Mas por D13.4 a supressão migrada é da **pessoa** (`contact_id`, `canal IS NULL`), não da
   identidade: quem pediu para sair pediu para sair de tudo.
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

## Decisões tomadas

Registradas como D13 em `DECISOES.md`. Cada uma está materializada em
`backfill/mapa_status.sql` e coberta por teste.

### D13.1 — `reengaging` vira enrollment novo em campanha própria

`rescue-reengage` implementa uma camada 2 com `layer2_step` e `layer2_last_sent_at` próprios. O
modelo novo não tem camadas, tem enrollments. O lead em `reengaging` chegou lá porque respondeu:
o enrollment original encerra por `resposta`, e o reengajamento é uma inscrição nova, numa campanha
de reengajamento com flow próprio.

*Por quê:* fica explícito, contável e reutilizável por qualquer campanha — não só resgate. A
alternativa (passo extra no mesmo flow) migraria mais barato, mas reintroduziria a camada dentro do
enrollment e sumiria com a distinção no relatório.

### D13.2 — `waiting_cycle` encerra e reinscreve

Campanha com `cycle_enabled` reinicia o lead após `cycle_interval_days`. No modelo novo isso é
`encerrado` / `fim_dos_passos`, mais um enrollment novo com `next_run_at = next_scheduled_at`.

*Por quê:* mantém a regra "um enrollment é uma passada pelo flow", preserva o histórico de cada
ciclo separadamente, e convive com o índice único de enrollment ativo por campanha. Manter `ativo`
com o passo zerado colapsaria todos os ciclos num registro só.

### D13.3 — Existe `cancelado_operacional` no enum

Migration `20260916140000_motivo_cancelado_operacional.sql`. `cancelled` (nos três pipelines) e o
`discarded` manual do blast não são resposta, nem mudança de etapa, nem fim dos passos, nem
supressão, nem falha.

*Por quê:* forçá-los em `falha_permanente` faria o relatório contar decisão humana como falha do
motor. Aditivo antes do backfill é barato; depois de haver dado gravado com o motivo errado, não é.

### D13.4 — Supressão migrada alcança a pessoa, não só o número

`contact_blacklist` (só telefone) vira `suppression (contact_id, canal IS NULL)` — todos os canais.
E `discarded` sem `discarded_reason` é tratado como opt-out.

*Por quê:* quem pediu para sair do WhatsApp não autorizou e-mail frio, e o `CLAUDE.md` descreve a
lista como global. Nos dois casos o erro cai para o lado de não incomodar: suprimir alguém
descartado por engano custa um lead; remessagear quem pediu para sair custa reclamação de LGPD e
remetente queimado.

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
