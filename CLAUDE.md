# CLAUDE.md — Motor de Prospecção Multicanal

## O que é este projeto

Serviço **autônomo** de cadência multicanal. Recebe contatos de fontes externas (planilha, CRM),
inscreve em flows de mensagens, executa a cadência ao longo do tempo em múltiplos canais, e escreve
de volta no CRM os fatos que descobre.

**Não é um disparador.** Disparador itera uma lista e o estado vive na execução. Aqui o estado vive
no contato, e a execução é um worker que acorda e pergunta "quem está vencido agora?".
Se uma mudança proposta só faz sentido num modelo de lote, ela está errada.

---

## Arquitetura em uma página

```
Fontes ──▶ Ingestão ──▶ contacts / contact_identities
                              │
                              ▼
                        enrollments  ◀──────────┐
                     (estado + next_run_at)     │
                              │                 │
                              ▼                 │
                         Agendador              │
                              │                 │
                              ▼                 │
                    Roteador de canal           │
             (lê tipo_campanha → escolhe        │
              identidade + sender_account)      │
                              │                 │
                              ▼                 │
                      ChannelAdapter            │
              email · whatsapp · sms · instagram│
                              │                 │
                              ▼                 │
                    Provedor externo            │
                              │                 │
                              ▼                 │
                   message_events ──────────────┘
                              │
                              ▼
                     outbox → writeback CRM
```

**Tabelas centrais:** `contacts`, `contact_identities`, `campaigns`, `flows`, `flow_versions`,
`flow_steps`, `enrollments`, `messages`, `message_events`, `sender_accounts`, `suppression`, `outbox`.

`enrollments` é o coração do sistema. Índice parcial em `(next_run_at) WHERE status = 'ativo'`.

---

## Invariantes — nunca quebrar

Estas quatro garantias definem o que "robusto" significa aqui. **Toda mudança precisa preservá-las,
e elas têm teste automatizado obrigatório.**

1. **Idempotência.** Toda mensagem tem chave única `(enrollment_id, step_id)`. Reprocessar nunca
   duplica disparo. Batch do agendador usa `SELECT ... FOR UPDATE SKIP LOCKED`.
2. **Supressão.** Contato em `suppression` nunca recebe nada, por nenhum caminho de código.
   A checagem acontece no roteador, antes do adapter — não dentro de cada adapter.
3. **Rate limit por remetente.** Nenhum `sender_account` ultrapassa sua quota. Conta com erro sai do
   pool sozinha (circuit breaker) e os pendentes rebalanceiam.
4. **Encerramento global.** Resposta em qualquer canal encerra o enrollment inteiro, não só o passo.

---

## Anti-regras

- **Nunca** recriar tabela que já existe. Consultar o schema antes de propor migration.
- **Nunca** gravar token do Pipefy. Sempre gerar via `client_credentials` no `_shared/pipefy.ts`,
  que é a única fonte de verdade desse OAuth.
- **Nunca** colocar secret fora do Vault. Nem em env de edge function, nem em constante, nem em teste.
- **Nunca** implementar envio que não passe pelo roteador (e portanto pelo gate de supressão).
- **Nunca** escrever no CRM de forma síncrona dentro do caminho de envio. Writeback vai por `outbox`.
- **Nunca** sobrescrever no CRM um campo do qual o CRM é dono. Contrato de escrita é estreito:
  `opt_out`, `identidade_invalida`, `respondeu`, `campanha_concluida`.
- **Nunca** editar um `flow_version` existente. Editar flow cria versão nova; enrollments em curso
  permanecem na versão antiga.
- **Nunca** modelar tabela por canal. Canal é adapter; pessoa é `contact`; endereço é
  `contact_identity`.
- **Nunca** deixar campanha fria usar remetente ou domínio da operação institucional.
- **Nunca** encerrar enrollment por clique em link. Clique é engajamento, não resposta.

---

## Convenções

- **Adapters:** entrada implementa `ContactSource`; saída implementa `ChannelAdapter`
  (`send`, `normalizeWebhook`, `checkHealth`). Canal novo = classe nova, zero mudança no motor.
- **Eventos:** `message_events` é append-only. Status nunca é sobrescrito, é derivado.
- **Migrations:** incrementais e reversíveis. `flow_steps.condicoes` (JSONB) já existe desde a
  primeira migration mesmo sem uso na v1.
- **Shadow mode:** `messages.status = 'simulado'` é caminho de primeira classe, não gambiarra de
  teste. O motor precisa rodar completo sem enviar nada.
- **Autoria:** toda escrita externa marca origem, para que o webhook de retorno descarte o próprio eco.

---

## Fase atual

> **Fase 2 — schema central.**
> O schema das 12 tabelas existe em `supabase/migrations/`, com as quatro invariantes garantidas
> por constraint e trigger, não por convenção. O agendador e o roteador existem
> (`processar_vencidos`), decidem e reivindicam sem enviar — o que torna a Fase 3 possível sem
> nenhum adapter. O mapa de status do backfill está fechado em `backfill/mapa_status.sql`.
>
> A Fase 1 tem três adapters em `adapters/` (Evolution, Meta Cloud, Comtele) com a superfície de
> despacho em SQL (`reivindicar_pendentes`, `registrar_resultado_envio`,
> `registrar_evento_provedor`). E-mail e Instagram ainda não têm adapter, e o registro declara isso.
>
> O worker existe (`supabase/functions/motor-worker`), roda em `simulado` por padrão, e com ele a
> **Fase 3 está completa de ponta a ponta**: agendador, roteador, adapters e despacho rodam sem
> enviar nada.
>
> Falta da Fase 2: o backfill em si, que depende de acesso aos dados do projeto legado
> `gtivnngoeccqbvfjiyne` — e com ele a comparação contra o Disparador.
>
> Toda mudança de schema roda `tests/run.sh` antes do commit. Teste vermelho é bloqueio, não aviso.

**Fase 0 concluída** — inventário em `INVENTARIO-FASE-0.md`: 83 edge functions e 52 tabelas
classificadas em migra/adapta/descarta. Leitura obrigatória antes de propor qualquer migração de
código antigo; várias suposições do `DECISOES.md` foram corrigidas lá (em especial: UAZAPI não
existe na base — o WhatsApp não-oficial é Evolution API).

A Fase 1 (`ChannelAdapter`) vem depois do schema — ver D12 em `DECISOES.md`.
Demais fases em `DECISOES.md`.

---

## Glossário de domínio

| Termo | Significado |
|---|---|
| **Enrollment** | Inscrição de um contato em uma versão de flow. Carrega o estado e o `next_run_at`. |
| **Identity** | Endereço de um contato num canal (e-mail, telefone, handle). Um contato tem N. |
| **Sender account** | Remetente físico: inbox, chip, número oficial. Tem quota e health score. |
| **Tipo de campanha** | Morna (base própria, opt-in) ou fria. Define base legal, canais e pool permitidos. |
| **Resgate** | Reativação de oportunidade antiga da base própria. |
| **Supressão** | Lista global e imutável de quem não pode receber nada. Acima de qualquer regra. |
