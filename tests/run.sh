#!/usr/bin/env bash
# Roda os testes das invariantes contra um Postgres descartável.
#
#   tests/run.sh
#
# Usa PGHOST/PGPORT/PGUSER do ambiente (padrão: socket local em /tmp, 5433).
# Cria um banco novo, aplica a migration, roda as asserções, verifica que a
# migration reverte, e derruba o banco.

set -euo pipefail

PGHOST="${PGHOST:-/tmp}"
PGPORT="${PGPORT:-5433}"
PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$RAIZ/supabase/migrations/20260916120000_motor_core.sql"
DOWN="$RAIZ/supabase/down/20260916120000_motor_core.down.sql"
BANCO="prospecta_teste_$$"

limpar() { psql -q -d postgres -c "DROP DATABASE IF EXISTS $BANCO" >/dev/null 2>&1 || true; }
trap limpar EXIT

echo "→ banco de teste: $BANCO"
psql -q -d postgres -c "CREATE DATABASE $BANCO"

echo "→ aplicando migration"
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$MIGRATION"

echo "→ rodando asserções"
psql -v ON_ERROR_STOP=1 -d "$BANCO" -f "$RAIZ/tests/invariantes.sql"

# ---------------------------------------------------------------------------
# Concorrência: o agendador precisa de SKIP LOCKED de verdade, não só no texto
# da função. Duas sessões simultâneas têm que pegar lotes disjuntos.
# ---------------------------------------------------------------------------
echo ""
echo "→ concorrência do agendador (SKIP LOCKED)"

TOTAL=$(psql -tA -d "$BANCO" -c "SELECT count(*) FROM proximos_vencidos(100)")

# Sessão A segura o primeiro vencido dentro de uma transação aberta.
psql -q -d "$BANCO" -c "BEGIN; SELECT * FROM proximos_vencidos(1); SELECT pg_sleep(4); COMMIT;" &
SESSAO_A=$!

# Espera a sessão A pegar a trava (pg_sleep, não sleep de shell).
psql -tAq -d "$BANCO" -c "SELECT pg_sleep(1)" >/dev/null

RESTANTE=$(psql -tA -d "$BANCO" -c "SELECT count(*) FROM proximos_vencidos(100)")
wait $SESSAO_A

ESPERADO=$((TOTAL - 1))
if [ "$RESTANTE" -eq "$ESPERADO" ]; then
  echo "PASS  agendador: sessão concorrente pula a linha travada ($RESTANTE de $TOTAL)"
else
  echo "FALHA agendador: esperava $ESPERADO vencidos na sessão concorrente, veio $RESTANTE"
  echo "      (sem SKIP LOCKED a segunda sessão ficaria bloqueada ou devolveria a mesma linha)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Reversibilidade: a migration tem que voltar atrás sem deixar resto.
# ---------------------------------------------------------------------------
echo ""
echo "→ reversibilidade da migration"
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -c "DROP SCHEMA t CASCADE" >/dev/null
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$DOWN"

RESTOS=$(psql -tA -d "$BANCO" -c "
  SELECT count(*) FROM pg_tables WHERE schemaname = 'public'
  UNION ALL SELECT count(*) FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
   WHERE n.nspname = 'public' AND t.typtype = 'e';" | paste -sd+ | bc)

if [ "$RESTOS" -eq 0 ]; then
  echo "PASS  migration reverte sem deixar tabela nem tipo para trás"
else
  echo "FALHA down deixou $RESTOS objeto(s) no schema public"
  exit 1
fi

# E aplica de novo, para provar que o ciclo up→down→up fecha.
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$MIGRATION"
echo "PASS  migration reaplica limpa após o down"

echo ""
echo "Tudo verde."
