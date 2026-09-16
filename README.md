# Motor de Prospecção Multicanal

Serviço autônomo de cadência multicanal. O estado vive no contato; a execução é um worker que acorda
e pergunta "quem está vencido agora?".

Contexto e regras do projeto em [`CLAUDE.md`](CLAUDE.md).
Decisões de arquitetura em [`DECISOES.md`](DECISOES.md).
Inventário dos sistemas que ele substitui em [`INVENTARIO-FASE-0.md`](INVENTARIO-FASE-0.md).
Mapa de `status` legado → modelo novo em [`MAPA-STATUS.md`](MAPA-STATUS.md).

## Estrutura

```
supabase/migrations/   schema, incremental
supabase/down/         reversão de cada migration
backfill/              ferramentas da migração de dados (fora do schema de runtime)
tests/                 testes das invariantes e do mapa de status
```

## Rodando os testes

As quatro invariantes do `CLAUDE.md` têm teste obrigatório. O suite sobe um banco descartável,
aplica a migration, roda as asserções, confirma que a migration reverte e reaplica.

```bash
# Postgres local (qualquer 16+)
PGHOST=/tmp PGPORT=5433 PGUSER=postgres tests/run.sh
```

Sem um Postgres à mão, um cluster descartável resolve:

```bash
PGBIN=/usr/lib/postgresql/16/bin
D=/var/lib/postgresql/prospecta-test
su postgres -c "$PGBIN/initdb -D $D -U postgres --auth=trust"
su postgres -c "$PGBIN/pg_ctl -D $D -o '-p 5433 -k /tmp' -l $D/log start"
```

O que o suite cobre:

| Invariante | Como é garantida | Como é testada |
|---|---|---|
| 1 — Idempotência | `UNIQUE (enrollment_id, step_id)` em `messages`; `proximos_vencidos()` com `FOR UPDATE SKIP LOCKED` | Reinserção do mesmo passo é recusada; duas sessões simultâneas pegam lotes disjuntos |
| 2 — Supressão | `esta_suprimido()` + trigger `messages_respeita_supressao` no INSERT | Contato e identidade suprimidos são barrados, inclusive em shadow mode |
| 3 — Rate limit | `CHECK (enviados_na_janela <= quota_diaria)`; `reservar_envio()` atômico; circuit breaker | Reserva além da quota é negada; 5 falhas abrem o circuito e tiram a conta do pool |
| 4 — Encerramento global | Trigger `message_events_encerra_enrollment` | Resposta encerra todos os enrollments do contato; clique não encerra (D7) |

Também cobre D2 (dedup de identidade), D3 (contrato estreito da outbox), D4 (isolamento morna/fria),
D9 (`flow_versions` imutáveis) e `message_events` append-only.

O mapa de status do backfill (`backfill/mapa_status.sql`) tem suite própria: os 27 valores dos três
vocabulários legados, mais as propriedades que importam — `sent` significa coisas opostas conforme a
origem, status desconhecido derruba o backfill em vez de inventar estado, todo encerrado tem motivo,
e só quem tem registro de saída pede supressão.

## Convenção

Teste vermelho é bloqueio, não aviso. Toda mudança de schema roda `tests/run.sh` antes do commit.
