# Fase 0 — Inventário read-only

> Levantamento dos sistemas existentes, classificando cada item em **migra / adapta / descarta**.
> Nenhum código foi alterado. Data do levantamento: 2026-09-16.

---

## Método e alcance

**Lido:** os quatro repositórios em `afinix-corretora`, no HEAD de cada branch default —
código-fonte das edge functions, migrations SQL e configuração.

**Alcançável ao vivo:** apenas o projeto Supabase `profitcare-crm` (`tjtmjflqgwjwcxfclzew`),
único da organização `Grupoafx` exposto pelo MCP.

**Não alcançável ao vivo:** os três projetos Supabase dos sistemas SDR. Os `project_id` estão nos
`config.toml` dos repos, mas nenhum pertence à organização acessível. Para esses, **crons e
functions de fato implantadas foram inferidos das migrations e do código** — não confirmados contra
produção. Ver [Lacunas](#lacunas-do-inventário).

---

## Correção de nomenclatura

Os nomes no `CLAUDE.md` não batem com os repositórios. Correspondência estabelecida:

| Nome no `CLAUDE.md` | Repositório real | Projeto Supabase | Observação |
|---|---|---|---|
| `sdr-resgate-evolution` | `afinix-corretora/sdr-resgate-evolution` | `gtivnngoeccqbvfjiyne` | Existe. Sistema principal. |
| `nina-sdr-evolution` | `afinix-corretora/sdr-evolution` | `ofuvzohyvkzozlscnzow` | Nome real é `sdr-evolution`. "Nina" é o agente de IA dentro dele. |
| `AqueceJá` | — | — | **Não é um projeto.** É o módulo `warming-*` dentro de `sdr-evolution` e `sdr-resgate-evolution`. |
| `ProfitCare` | `afinix-corretora/project-cb5d08` | `mnowzzftjukjchakghcl` (repo) / `tjtmjflqgwjwcxfclzew` (live) | Chama-se "CRM Afinix"/"SeguroCRM". Dois project_ids — ver abaixo. |
| — | `afinix-corretora/sdr` | `odafxdafbnbhvaijyite` | **Quarto sistema, não citado no `CLAUDE.md`.** Ancestral de `sdr-evolution`. |

### A linhagem dos SDR é uma cadeia, não três sistemas

`sdr` (2026-03) → `sdr-evolution` (2026-05) → `sdr-resgate-evolution` (2026-07).

Verificado por comparação de conjuntos: **o conjunto de edge functions de `sdr-resgate-evolution`
é superconjunto estrito dos outros dois** — zero functions exclusivas em `sdr-evolution` (47) ou em
`sdr` (17). Mesma relação nas migrations (97 / 63 / 48) e nas tabelas.

Consequência: só `sdr-resgate-evolution` precisa de inventário item a item. Os outros dois são
snapshots históricos, ainda com projeto Supabase próprio e presumivelmente ligado.

### ProfitCare aponta para dois projetos

`project-cb5d08/supabase/config.toml` declara `mnowzzftjukjchakghcl`, mas o projeto vivo da
organização é `tjtmjflqgwjwcxfclzew` (`profitcare-crm`), que tem implantadas as functions `crm-*` e
`pipefy-*` do repo **mais quatro que não existem no repo**: `diag-env`, `diag-email`, `diag-pipefy`,
`migrate-bridge`. Somado aos secrets `DEST_SUPABASE_URL` / `DEST_SERVICE_ROLE` e à function
`exportar-para-supabase`, o quadro é de **migração de projeto em andamento**, com drift entre repo e
produção. Precisa de confirmação de quem conduziu.

---

## Achado principal — WhatsApp existe em cinco implementações

O `CLAUDE.md` suspeitava de duplicação. É pior do que duplicação: são **cinco caminhos de envio
sobrepostos, sem interface comum**, todos em `sdr-resgate-evolution`.

| # | Função | Provedores que fala | Como escolhe |
|---|---|---|---|
| 1 | `send-evolution-message` | Evolution API (não-oficial), `api_url` vindo do banco | Não escolhe — sempre Evolution |
| 2 | `whatsapp-sender` (787 linhas) | Evolution **e** Meta Graph `v18.0` hardcoded | `messaging_provider`, com fallback por presença de `official_api_config_id`/`instance_id` |
| 3 | `meta-send-via-bsp` (344 linhas) | Meta Cloud, Gupshup, Twilio, Z-API, 360dialog | `switch` interno por método |
| 4 | `gupshup-send-session` | Gupshup | Não escolhe |
| 5 | `broadcast-processor` / `blast-engine` / `rescue-engine` | cada um chama 1–3 —  ternário próprio | Cada motor reimplementa o roteamento |

Na entrada, **sete normalizadores de webhook** para os mesmos eventos: `evolution-webhook`
(1177 linhas), `whatsapp-webhook`, `gupshup-webhook`, `meta-webhook`, `bsp-webhook`,
`rescue-webhook-inbound`, `inbound-lead-webhook`.

**UAZAPI não existe no código.** Busca por `uaz` em todos os repos retorna apenas um match em
`package-lock.json` (coincidência de hash). O `DECISOES.md` lista o cliente UAZAPI entre os que
"migram quase intatos" — **não há o que migrar**. O WhatsApp não-oficial hoje é Evolution API
(`evolutionapi.grupoafx.com.br`, self-hosted). Isso muda o escopo de D6 e do spike S1: ou se adota
Evolution como pool não-oficial (código já existe e roda), ou UAZAPI é construção nova, não migração.

---

## Riscos contra as invariantes do motor novo

Cada item abaixo foi verificado no código. São as razões concretas pelas quais o motor novo precisa
existir — e o que não pode ser copiado junto.

### 1. O gate de supressão não cobre o caminho de envio

`is_phone_blacklisted` é consultado por 14 functions, **mas por nenhuma das que de fato enviam**
(`send-evolution-message`, `whatsapp-sender`, `meta-send-via-bsp`, `gupshup-send-session`,
`comtele-send-sms`). A checagem vive nos chamadores — `blast-engine`, `rescue-engine`,
`broadcast-processor`, `rescue-reengage`, `nina-orchestrator` — cada um com sua própria cópia.
Qualquer invocação direta de uma function de envio contorna a supressão.

Isto valida literalmente a invariante 2 do projeto novo ("a checagem acontece no roteador, antes do
adapter"), com a ressalva de que aqui existem cinco roteadores, não um.

Além disso, `contact_blacklist` é **indexada só por telefone** (`regexp_replace(phone,'\D','','g')`).
Não há supressão de e-mail nem de handle — a tabela `suppression` nova não tem backfill direto para
canais que não sejam WhatsApp/SMS.

### 2. Idempotência: um motor acerta, os outros não

`rescue-engine` resolve bem — reivindica o passo inserindo em `rescue_message_logs` **antes** de
enviar, apoiado num índice único parcial em `(lead_id, sequence_order) WHERE status <> 'failed'`.
Concorrência colide no insert e só um runner segue. É o ancestral direto da chave
`(enrollment_id, step_id)` e deve ser preservado como padrão.

`blast-engine` usa status-como-mutex: `UPDATE ... SET status='processing' WHERE status='pending'`,
com requeue de travados. Nenhuma trava de banco. É exatamente o padrão que o `DECISOES.md` manda
descartar — e as functions `audit-stuck-leads`, `fix-stuck-leads`, `reprocess-stuck-leads`,
`auto-requeue-messages` e `merge-and-resume` existem **para limpar o rastro dele**.

Nenhum dos motores usa `FOR UPDATE SKIP LOCKED`.

### 3. Não existe rate limit por remetente

Não há quota nem circuit breaker. O que existe é um `delay_min_seconds`/`delay_max_seconds` por
campanha — e ele é neutralizado no próprio código:

```ts
await new Promise(r => setTimeout(r, Math.min(delaySec, 5) * 1000)); // máximo 5s no edge
```

O delay configurado (30–120s) é truncado em 5s porque a edge function tem limite de execução.
O operador configura um intervalo que o sistema não respeita. O health score de remetente só existe
no módulo `warming-*`, desconectado do envio.

### 4. Encerramento é por polling, por campanha, num canal só

`rescue-response-reconciler` roda a cada minuto, varre até 200 leads e marca `responded` se houver
mensagem recebida após o último envio. É uma rede de segurança, não um gate: cobre só
`rescue_leads`, só conversas de WhatsApp, e com atraso de até um minuto. Não há encerramento global
entre canais.

### 5. Modelagem por canal e por caso de uso

Três pipelines paralelos com tabelas próprias e quase idênticas:
`rescue_campaigns`/`rescue_leads`/`rescue_messages`/`rescue_message_logs`,
`blast_campaigns`/`blast_leads`/`blast_message_logs`,
`broadcast_campaigns`/`broadcast_recipients`. É o que `contacts` + `enrollments` + `messages`
unificam.

### 6. Credenciais fora do Vault

- **Anon JWT hardcoded** na migration `20260420192348_*.sql`, no corpo do `cron.schedule` do
  `rescue-engine`, versionado no git. É chave publicável (baixo impacto direto), mas é credencial em
  migration, e fixa o project ref no SQL.
- `pipefy_oauth_tokens` ainda aceita **coluna `access_token` em texto puro** como fallback legado em
  `_shared/pipefy.ts`. O caminho novo (Vault via `get_decrypted_meta_token`) já existe; o antigo
  precisa de data para morrer.
- `.env` versionado nos quatro repos — verificado: contém só URL e chave publicável, **sem
  secret real**. Baixo risco, mas deve sair.
- Secrets de provedor vivem em `whatsapp_instance_secrets`, `gupshup_config`, `comtele_credentials`,
  `pipefy_credentials`. Os quatro já usam Vault nas functions novas; `send-evolution-message` lê
  `api_url, api_key` direto da tabela.
- `project-cb5d08` usa `PIPEFY_API_TOKEN` (token estático) **além** de `PIPEFY_CLIENT_ID/SECRET`.
  Contraria a anti-regra do Pipefy. `_shared/pipefy.ts` do `sdr-resgate-evolution` é a implementação
  correta e deve ser a única.

### 7. ProfitCare já tem duplicação interna de contatos

No projeto vivo (72 tabelas): `contacts` **e** `contatos`; `cards` **e** `crm_cards`; `pipelines`
**e** `funis`; mais cinco tabelas `*_backup_*`. Como o motor novo tem `contacts` próprios (D1) e não
faz join com o CRM, isso não bloqueia — mas define qual lado é dono de quê no writeback de D3, e a
resposta hoje é ambígua.

---

## Classificação — edge functions de `sdr-resgate-evolution`

83 functions + o módulo `_shared`. Todas classificadas, nenhuma sem veredicto.
**Adapta 43 · Descarta 32 · Migra 8.**

### Migra quase intacto (8)

| Function | Por quê |
|---|---|
| `_shared/pipefy.ts` | OAuth `client_credentials` com Vault e cache compartilhado. É a fonte de verdade que o `CLAUDE.md` já protege. Migra removendo o fallback de token em texto puro. |
| `comtele-send-sms` | Cliente limpo, uma responsabilidade, normalização DDI+DDD. Vira `SmsComteleAdapter.send()` quase sem mudança. |
| `pipefy-credentials`, `fetch-pipefy-fields`, `fetch-pipefy-pipes`, `pipefy-diagnostic` | Configuração e diagnóstico de Pipefy, sem acoplamento ao modelo de lote. |
| `rescue-upload-csv`, `blast-upload-csv` | UX de upload multi-formato que o `DECISOES.md` quer preservar. Vira `PlanilhaSource`. |
| `blast-ai-summarize` | Resumo por IA, também citado como a preservar. Independente do motor. |

### Adapta (43)

| Grupo | Functions | Destino |
|---|---|---|
| Saída de canal (5) | `send-evolution-message`, `whatsapp-sender`, `meta-send-via-bsp`, `gupshup-send-session`, `gupshup-send-test-message` | Colapsam em `ChannelAdapter.send()` — um adapter por provedor. São cinco provedores implementados, não três: Evolution, Meta Cloud, Gupshup, Twilio, Z-API/360dialog. |
| Entrada de canal (7) | `evolution-webhook`, `whatsapp-webhook`, `gupshup-webhook`, `meta-webhook`, `bsp-webhook`, `rescue-webhook-inbound`, `inbound-lead-webhook` | Colapsam em `ChannelAdapter.normalizeWebhook()`. As 1177 linhas do `evolution-webhook` são o maior item isolado de trabalho da Fase 1. |
| Cadência (3) | `rescue-engine`, `rescue-reengage`, `rescue-response-reconciler` | Núcleo do agendador novo. `rescue-engine` já tem estado por lead, janela de envio, ciclo e claim idempotente. |
| CRM (3) | `rescue-pipefy-poller`, `rescue-pipefy-webhook`, `dispatch-integration` | Poller e webhook viram `PipefySource`. `dispatch-integration` (817 linhas, Pipefy+HubSpot+Pipedrive) vira writeback via `outbox` — hoje é síncrono no caminho de envio. |
| Detecção de resposta (3) | `detect-optout-intent`, `analyze-conversation`, `message-grouper` | O classificador citado no `DECISOES.md`. Só a parte "respondeu / pediu opt-out" entra na v1. |
| Pool de remetentes (13) | `warming-*` (4), `*-evolution-instance(s)` (5), `check-instances-status`, `update-evolution-settings`, `validate-whatsapp-numbers`, `comtele-credentials` | Viram `sender_accounts` com quota e health score. O módulo de warming é a origem do health score. |
| Templates e métricas (9) | `meta-sync-templates`, `meta-submit-template`, `meta-sync-metrics`, `meta-connect-api`, `gupshup-submit-template`, `gupshup-sync-templates`, `gupshup-sync-metrics`, `gupshup-validate-config`, `sync-all-templates` | Templates aprovados são pré-requisito do WhatsApp oficial. Entram como configuração de `flow_steps`. |

### Descarta (32)

| Grupo | Functions | Por quê |
|---|---|---|
| Motores de lote (2) | `blast-engine`, `broadcast-processor` | Modelo de lote com status-como-mutex. Substituídos pelo agendador. A UX do Disparador sobrevive; o motor não. |
| Gatilhos de cron (2) | `trigger-whatsapp-sender`, `trigger-nina-orchestrator` | Substituídos pelo agendador único. |
| Limpeza de travados (5) | `audit-stuck-leads`, `fix-stuck-leads`, `reprocess-stuck-leads`, `auto-requeue-messages`, `merge-and-resume` | Existem só para consertar o mutex por status. Sem a causa, somem. |
| Agente de IA (6) | `nina-orchestrator` (1921 linhas), `generate-prompt`, `generate-embeddings`, `test-prompt-chat`, `test-full-qualification`, `search-social-profiles` | Nina é agente conversacional de qualificação — produto diferente do motor de cadência. Fica onde está; o motor entrega o lead e sai. |
| Infra, teste e uso único (17) | `health-check`, `initialize-system`, `import-settings`, `validate-setup`, `debug-pipeline`, `invite-team-member`, `seed-appointments`, `simulate-webhook`, `simulate-audio-webhook`, `test-appointment-webhook`, `test-elevenlabs-tts`, `test-whatsapp-message`, `merge-duplicate-contacts`, `validate-contacts`, `blast-create-card`, `blast-delete-card`, `blast-mark-disregard` | Scaffolding, testes manuais e operações acopladas ao schema antigo. Nada a preservar. |

---

## Classificação — tabelas de `sdr-resgate-evolution`

52 tabelas, todas classificadas. **Adapta 31 · Descarta 19 · Migra 2.**
A coluna "destino" usa os nomes do schema novo definido no `CLAUDE.md`.

### Adapta — vira schema novo (31)

| Destino | Tabelas de origem | Nota |
|---|---|---|
| `contacts` / `contact_identities` | `contacts` | Backfill com dedup (Fase 2). Hoje a identidade é coluna `phone_number` no próprio contato — não há tabela de identidades, então `contact_identities` nasce vazia e é populada a partir daí. |
| `suppression` | `contact_blacklist` | Só telefone. Migra 1:1 para o canal WhatsApp/SMS; e-mail e handle nascem sem histórico. |
| `campaigns` | `rescue_campaigns`, `blast_campaigns`, `broadcast_campaigns` | Três tabelas quase idênticas viram uma. `tipo_campanha` (D4) não existe em nenhuma — é campo novo, não migrado. |
| `flows` / `flow_versions` / `flow_steps` | `rescue_messages`, `meta_templates` | `rescue_messages` já tem `sequence_order` e `layer` — é a cadência linear da v1 (D8). Não há versionamento: os passos são editáveis em lugar, exatamente o que D9 proíbe. |
| `enrollments` | `rescue_leads`, `blast_leads`, `broadcast_recipients` | `rescue_leads` é o mais próximo: já tem `current_step`, `next_scheduled_at`, `cycle_count`, `status`. `blast_leads` traz `wa_status`/`sms_status` por canal — no modelo novo isso são `messages`, não colunas. |
| `messages` / `message_events` | `rescue_message_logs`, `blast_message_logs`, `messages`, `conversations`, `conversation_states` | `rescue_message_logs` carrega o índice único parcial que garante a idempotência — preservar o padrão. `conversation_states` é estado sobrescrito; `message_events` é append-only, então vira derivação, não migração. |
| `sender_accounts` | `whatsapp_instances`, `whatsapp_instance_secrets`, `official_api_configs`, `official_api_metrics`, `gupshup_config`, `gupshup_partner_accounts`, `comtele_credentials`, `round_robin_state` | Oito tabelas, uma por provedor — é a modelagem por canal que a anti-regra proíbe. `round_robin_state` é o embrião do pool; não tem quota nem health score. |
| health score de `sender_accounts` | `warming_chips`, `warming_groups`, `warming_group_members`, `warming_messages`, `warming_pairs`, `warming_phases` | O módulo "AqueceJá". Tem a noção de fase de aquecimento e de chip, que é o que falta no pool de envio. Hoje vive isolado do caminho de disparo. |
| `outbox` | `integration_destinations`, `integration_logs` | Destinos e log de writeback existem; o que não existe é a fila assíncrona com retry (D3) — hoje `dispatch-integration` escreve inline. |

### Migra (2)

`pipefy_credentials` e `pipefy_oauth_tokens` — o par que sustenta `_shared/pipefy.ts`. Migram
como estão, **menos a coluna `access_token` em texto puro**, cujo fallback deve morrer junto.

### Descarta (19)

| Grupo | Tabelas | Por quê |
|---|---|---|
| Filas de execução (4) | `send_queue`, `message_grouping_queue`, `message_processing_queue`, `nina_processing_queue` | Fila com estado na execução. O modelo novo põe o estado no contato: a "fila" é `enrollments.next_run_at` com índice parcial. |
| Nina / RAG (3) | `nina_settings`, `knowledge_chunks`, `knowledge_files` | Pertencem ao agente conversacional, não ao motor. |
| CRM embutido (6) | `deals`, `deal_activities`, `appointments`, `pipelines`, `pipeline_stages`, `tag_definitions` | O motor não tem CRM próprio (D1) — lê e escreve no Pipefy/ProfitCare por contrato estreito (D3). |
| Aplicação (6) | `profiles`, `teams`, `team_members`, `team_functions`, `user_roles`, `design_settings` | Multi-tenant e UI do produto antigo. O serviço novo é autônomo, com API própria. |

### O risco real da Fase 2 é o vocabulário de `status`, não o volume

O backfill é 3 → 1 em campanha, lead e log. O que atrapalha é que os três pipelines usam
vocabulários diferentes e incoerentes entre si:

- **`rescue_leads`** — 14 valores no `CHECK` final: `pending`, `in_progress`, `responded`,
  `engaged`, `reengaging`, `qualified`, `disqualified`, `blacklisted`, `completed`,
  `waiting_cycle`, `failed`, `sent`, `paused`, `cancelled`. A restrição foi **alargada quatro vezes
  em seis semanas** (9 valores em 20/04 → 12 → 10 → 14 em 02/06). Uma coluna de status que só cresce
  é sintoma de estado que devia estar em outro lugar — no modelo novo isso se separa em
  `enrollments.status` (ciclo de vida da inscrição) e `message_events` (o que aconteceu com cada
  disparo).
- **`blast_leads`** — 8 valores, semântica disjunta: `pending`, `processing`, `sent`, `positive`,
  `discarded`, `blacklisted`, `failed`, `cancelled`. Mistura estado de entrega com **desfecho
  comercial** (`positive`, `discarded`), e ainda mantém `wa_status`/`sms_status` em paralelo, por
  canal, na mesma linha.

Há também **vocabulário morto**: `responded` está no `CHECK` de `rescue_leads` mas nenhuma function
escreve esse valor — `rescue-response-reconciler` grava `status: 'engaged'` com `responded_at`,
embora o próprio docstring dela diga "marks the lead as `responded`". Documentação e código já
divergem hoje; migrar sem decidir qual vence propaga a ambiguidade para o schema novo.

**Consequência prática:** o mapa de `status` antigo → (`enrollments.status` + evento) precisa ser
escrito e revisado **antes** do backfill. Sem ele o backfill inventa estado, e o shadow mode da
Fase 3 compara contra uma baseline que já nasce errada.

---

## Crons

| Projeto | Job | Frequência | Situação |
|---|---|---|---|
| `gtivnngoeccqbvfjiyne` (resgate) | `rescue-engine-every-minute` | `* * * * *` | Definido em migration, com anon JWT no corpo. **Não confirmado ao vivo.** |
| `tjtmjflqgwjwcxfclzew` (profitcare) | `crm-sheets-sync-every-1min` | `* * * * *` | Confirmado ativo |
| `tjtmjflqgwjwcxfclzew` | `migracao-pipefy-auto` | `*/2 * * * *` | Confirmado ativo. Job de migração — deve ter fim previsto. |

`sdr-evolution` e `sdr` habilitam `pg_cron` nas migrations mas **não agendam nada por migration**.
O comentário em `rescue-response-reconciler` diz "runs every minute via pg_cron" sem migration
correspondente — logo há jobs criados manualmente pelo painel, invisíveis no repo. Levantar no
projeto vivo é pré-requisito do cutover (Fase 4) e **não foi possível aqui**.

---

## Dependências externas

| Dependência | Onde | Veredicto |
|---|---|---|
| Evolution API (`evolutionapi.grupoafx.com.br`, self-hosted) | 3 repos SDR | **Adapta** — é o WhatsApp não-oficial real do grupo, no lugar do UAZAPI presumido |
| Meta Graph / WhatsApp Cloud API | `whatsapp-sender` (v18.0 fixo), `meta-*` | Adapta — unificar versão da API, hoje divergente |
| Gupshup (BSP) | 7 functions | Adapta |
| Comtele (SMS) | `comtele-send-sms`, `blast-engine` | Migra |
| Pipefy (OAuth client_credentials) | `_shared/pipefy.ts` + 6 functions | Migra |
| Twilio, Z-API, 360dialog | `meta-send-via-bsp`, `bsp-webhook`, `sync-all-templates` + formulários próprios na UI | **Adapta** — não é código morto (ver abaixo) |
| OpenAI / Lovable AI Gateway / ElevenLabs / Firecrawl | Nina, transcrição, enriquecimento | Descarta do motor (fica com Nina) |
| HubSpot, Pipedrive | `dispatch-integration` | Descarta na v1 — CRM é Pipefy/ProfitCare (D1, D3) |
| Google Sheets / OAuth, SMTP (`smtplw.com.br`) | ProfitCare | Fora do escopo do motor |
| n8n (`criadordigital-n8n-webhook...easypanel.host`) | uma URL fixa em `test-appointment-webhook` | **Descarta** — não é integração do motor (ver abaixo) |

### Os três BSPs extras são funcionalidade, não resíduo

Levantamento inicial sugeriu código morto. É o contrário: `official_api_configs.connection_method`
tem `CHECK` com `meta_direct`, `bsp_360dialog`, `bsp_gupshup`, `bsp_twilio`, `bsp_zapi`
(migration `20260423130820_*.sql`), e cada um tem formulário próprio na UI
(`TwilioForm.tsx`, `ZApiForm.tsx`, `Dialog360Form.tsx`, sob `BspSelector`), tratamento em
`bsp-webhook` e em `sync-all-templates`. É uma abstração multi-BSP deliberada — e é a coisa mais
próxima de um `ChannelAdapter` que já existe na base.

O que continua em aberto é **runtime, não código**: se há alguma conta de fato configurada em cada
BSP. Só se responde consultando `official_api_configs` no projeto vivo. A decisão de portar os cinco
ou só os usados depende disso.

### n8n está resolvido

Único ponto de contato é uma URL fixa no corpo de `test-appointment-webhook` — function de teste
manual, já classificada em descarta. Não há orquestração externa no caminho de envio.

---

## Lacunas do inventário

Itens que a Fase 0 pede e que **não foi possível fechar** com o acesso desta sessão:

1. **Crons reais dos três projetos SDR.** Só as migrations foram lidas; jobs criados pelo painel não
   aparecem. Resolve-se dando ao MCP acesso a `gtivnngoeccqbvfjiyne`, `ofuvzohyvkzozlscnzow` e
   `odafxdafbnbhvaijyite`, ou rodando `select jobname, schedule, active from cron.job` em cada um.
2. **Functions implantadas vs. versionadas** nesses três projetos. Em `profitcare-crm` o drift já
   apareceu (4 functions a mais em produção); não há razão para supor que os outros estejam limpos.
3. **Quais sistemas ainda estão em uso.** `sdr` e `sdr-evolution` não recebem commit há 4 e 6 meses,
   mas os projetos Supabase seguem de pé. Se estão desligados, são descarte imediato; se há tráfego,
   a Fase 5 tem três desligamentos, não um.
4. **Quais BSPs têm conta configurada.** O código dos cinco existe e é funcional; quantos estão em
   uso é dado de runtime — `select connection_method, count(*) from official_api_configs group by 1`.
5. **Qual projeto é o ProfitCare de verdade** — `mnowzzftjukjchakghcl` ou `tjtmjflqgwjwcxfclzew`.

Fechadas durante o levantamento: n8n (não é integração do motor) e Twilio/Z-API/360dialog
(funcionalidade real, não código morto).

---

## Consequências para as fases seguintes

- **Fase 1 (interface `ChannelAdapter`)** é maior do que o `DECISOES.md` supõe. Não é envolver três
  clientes de provedor: é colapsar 5 caminhos de saída e 7 de entrada. O `evolution-webhook`
  sozinho tem 1177 linhas. Em compensação, o cliente UAZAPI não precisa ser envolvido — não existe.
- **D6 e S1 precisam de revisão.** A decisão assume UAZAPI como o não-oficial. O que existe e roda é
  Evolution API self-hosted. Ou D6 passa a dizer Evolution, ou UAZAPI vira construção nova com custo
  de projeto, não de migração — e o spike S1 muda de "medir queima do UAZAPI" para "medir queima do
  pool Evolution atual", que pode começar com dados de produção já existentes.
- **Fase 2 (schema + backfill)** tem três pares campanha/lead a unificar
  (`rescue_*`, `blast_*`, `broadcast_*`) e uma `contact_blacklist` só de telefone para virar
  `suppression` multicanal.
- **Fase 3 (shadow mode)** ganha um comparador natural: `rescue-engine` roda a cada minuto com
  estado por lead e claim idempotente. Dá para rodar o motor novo em `simulado` contra os mesmos
  `rescue_leads` e comparar passo a passo — a comparação com o Disparador em lote é a mais difícil,
  não a mais fácil.
- **Fase 5 (deletar o caminho antigo)** tem pelo menos 32 functions e três projetos Supabase
  candidatos a desligamento, não um.
