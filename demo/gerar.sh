#!/usr/bin/env bash
# Roda o motor num cenário de demonstração e escreve demo/preview.json.
set -euo pipefail
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BANCO="prospecta_preview_$$"
trap 'psql -q -d postgres -c "DROP DATABASE IF EXISTS $BANCO" >/dev/null 2>&1 || true' EXIT
psql -q -d postgres -c "CREATE DATABASE $BANCO"
for m in "$RAIZ"/supabase/migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$m"; done
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$RAIZ/demo/preview.sql" > "$RAIZ/demo/preview.json"
echo "demo/preview.json: $(wc -c < "$RAIZ/demo/preview.json") bytes"
