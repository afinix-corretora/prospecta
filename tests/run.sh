#!/usr/bin/env bash
# Roda os testes contra um Postgres descartável.
#
#   tests/run.sh
#
# Usa PGHOST/PGPORT/PGUSER do ambiente (padrão: socket local em /tmp, 5433).
# Cria um banco novo, aplica todas as migrations em ordem, roda as asserções,
# verifica que os downs revertem em ordem inversa, e derruba o banco.

set -euo pipefail

PGHOST="${PGHOST:-/tmp}"
PGPORT="${PGPORT:-5433}"
PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BANCO="prospecta_teste_$$"

limpar() { psql -q -d postgres -c "DROP DATABASE IF EXISTS $BANCO" >/dev/null 2>&1 || true; }
trap limpar EXIT

aplicar_migrations() {
  for m in "$RAIZ"/supabase/migrations/*.sql; do
    psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$m"
  done
}

echo "→ banco de teste: $BANCO"
psql -q -d postgres -c "CREATE DATABASE $BANCO"

echo "→ aplicando migrations"
aplicar_migrations

echo "→ invariantes do schema"
psql -v ON_ERROR_STOP=1 -d "$BANCO" -f "$RAIZ/tests/invariantes.sql"

echo ""
echo "→ mapa de status do backfill"
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$RAIZ/backfill/mapa_status.sql"
psql -v ON_ERROR_STOP=1 -d "$BANCO" -f "$RAIZ/tests/mapa_status.sql"

# ---------------------------------------------------------------------------
# Concorrência: o agendador precisa de SKIP LOCKED de verdade, não só no texto
# da função. Duas sessões simultâneas têm que pegar lotes disjuntos.
# ---------------------------------------------------------------------------
echo ""
echo "→ agendador e roteador"
psql -v ON_ERROR_STOP=1 -d "$BANCO" -f "$RAIZ/tests/agendador.sql"

echo ""
echo "→ concorrência do agendador (SKIP LOCKED)"

TOTAL=$(psql -tA -d "$BANCO" -c "SELECT count(*) FROM proximos_vencidos(100)")

# Sessão A segura o primeiro vencido dentro de uma transação aberta.
psql -q -o /dev/null -d "$BANCO" \
  -c "BEGIN; SELECT * FROM proximos_vencidos(1); SELECT pg_sleep(4); COMMIT;" &
SESSAO_A=$!

# Espera a sessão A pegar a trava (pg_sleep, não sleep de shell).
psql -tAq -o /dev/null -d "$BANCO" -c "SELECT pg_sleep(1)"

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
# Reversibilidade: cada migration tem que voltar atrás sem deixar resto.
# ---------------------------------------------------------------------------
echo ""
echo "→ reversibilidade das migrations"
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" \
  -c "DROP SCHEMA t CASCADE; DROP SCHEMA m CASCADE; DROP SCHEMA a CASCADE" >/dev/null
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" \
  -c "DROP FUNCTION mapear_status_legado(text,text,jsonb); DROP TYPE acao_reinscricao" >/dev/null

# Ordem inversa da aplicação.
for d in $(ls -r "$RAIZ"/supabase/down/*.sql); do
  psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$d"
done

RESTOS=$(psql -tA -d "$BANCO" -c "
  SELECT (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')
       + (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
           WHERE n.nspname = 'public' AND t.typtype = 'e');")

if [ "$RESTOS" -eq 0 ]; then
  echo "PASS  migrations revertem sem deixar tabela nem tipo para trás"
else
  echo "FALHA down deixou $RESTOS objeto(s) no schema public"
  psql -d "$BANCO" -c "SELECT tablename FROM pg_tables WHERE schemaname='public'"
  exit 1
fi

# E aplica de novo, para provar que o ciclo up→down→up fecha.
aplicar_migrations
echo "PASS  migrations reaplicam limpas após o down"

echo ""
echo "Tudo verde."
