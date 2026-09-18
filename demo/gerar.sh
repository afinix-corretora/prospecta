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
# Mesmo preparo do suite: um tenant padrão para as fixtures não repetirem
# tenant_id, e `privado` no search_path porque o motor mora lá (D19).
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" <<SQL
INSERT INTO tenants (id, nome, slug)
VALUES ('00000000-0000-0000-0000-0000000000aa','Afinix Corretora','afinix');
ALTER DATABASE $BANCO SET app.tenant = '00000000-0000-0000-0000-0000000000aa';
ALTER DATABASE $BANCO SET search_path = public, privado;
SQL
psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$RAIZ/demo/preview.sql" > "$RAIZ/demo/preview.json"
echo "demo/preview.json: $(wc -c < "$RAIZ/demo/preview.json") bytes"
python3 "$RAIZ/demo/injetar.py"
