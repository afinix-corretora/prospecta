#!/usr/bin/env bash
# Roda o motor num cenário de demonstração e escreve demo/preview.json.
set -euo pipefail
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BANCO="prospecta_preview_$$"
limpar() {
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $BANCO" >/dev/null 2>&1 || true
  [ -n "${GERADO:-}" ] && rm -f "$GERADO"
  return 0
}
trap limpar EXIT
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
# A ingestão vem de `demo/contatos.csv`, pelo mesmo `PlanilhaSource` da tela.
# Gerar SQL e incluir com `\i` mantém o cenário num arquivo só e deixa a
# dependência à vista: o demo não semeia contato, ele importa.
GERADO="$(mktemp -t prospecta-ingestao-XXXXXX.sql)"
node --experimental-strip-types "$RAIZ/demo/ingerir.ts" > "$GERADO"

psql -q -v ON_ERROR_STOP=1 -v ingestao="$GERADO" \
  -d "$BANCO" -f "$RAIZ/demo/preview.sql" > "$RAIZ/demo/preview.json"
echo "demo/preview.json: $(wc -c < "$RAIZ/demo/preview.json") bytes"
python3 "$RAIZ/demo/conferir.py"
python3 "$RAIZ/demo/injetar.py"
