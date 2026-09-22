#!/usr/bin/env bash
# Roda a suite contra um Postgres descartável.
#
#   tests/run.sh
#
# Usa PGHOST/PGPORT/PGUSER do ambiente (padrão: socket local em /tmp, 5433).
#
# Cada arquivo de teste roda em banco próprio. Compartilhar banco faz um teste
# enxergar as fixtures do outro — já produziu duas falhas falsas aqui, uma por
# remetente ambíguo e outra por mensagem pendente alheia.

set -euo pipefail

PGHOST="${PGHOST:-/tmp}"
PGPORT="${PGPORT:-5433}"
PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIXO="prospecta_teste_$$"
BANCOS=()

limpar() {
  for b in "${BANCOS[@]:-}"; do
    [ -n "$b" ] && psql -q -d postgres -c "DROP DATABASE IF EXISTS $b" >/dev/null 2>&1 || true
  done
}
trap limpar EXIT

# Cria um banco com todas as migrations aplicadas e ecoa o nome.
novo_banco() {
  local nome="${PREFIXO}_$1"
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $nome" >/dev/null 2>&1 || true
  psql -q -d postgres -c "CREATE DATABASE $nome"
  BANCOS+=("$nome")
  for m in "$RAIZ"/supabase/migrations/*.sql; do
    psql -q -v ON_ERROR_STOP=1 -d "$nome" -f "$m"
  done
  # Papéis que o Supabase provê e o Postgres local não, e um tenant padrão
  # para as fixtures não repetirem tenant_id em cada INSERT.
  psql -q -v ON_ERROR_STOP=1 -d "$nome" <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END \$\$;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated;
-- Como no Supabase: anon tem o privilégio de SELECT, e quem nega é o RLS.
-- Se o privilégio faltasse, o teste passaria por "permission denied" e não
-- provaria nada sobre as políticas.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated;
-- Sem GRANT EXECUTE em massa: a migration de endurecimento decide, nominalmente,
-- o que o papel authenticated pode chamar. Conceder tudo aqui faria o teste
-- rodar numa superfície mais larga que a de produção.
--
-- Sem crase neste bloco, de propósito: o heredoc é \`<<SQL\` sem aspas, porque
-- precisa expandir \$nome — e aí a crase vira substituição de comando. Este
-- comentário rodava \`authenticated\` como programa a cada banco criado, o que
-- só não fez estrago porque o nome não existe.
INSERT INTO tenants (id, nome, slug)
VALUES ('00000000-0000-0000-0000-0000000000aa','Afinix Corretora','afinix');
ALTER DATABASE $nome SET app.tenant = '00000000-0000-0000-0000-0000000000aa';
-- As engrenagens do motor moram em \`privado\` (não publicada pelo PostgREST).
-- Os testes as chamam direto, como o faria um psql de manutenção.
ALTER DATABASE $nome SET search_path = public, privado;
SQL
  echo "$nome"
}

# rodar <rótulo> <arquivo-de-teste> [arquivos a carregar antes...]
rodar() {
  local rotulo="$1" teste="$2"; shift 2
  echo ""
  echo "→ $rotulo"
  local banco; banco="$(novo_banco "$rotulo")"
  for extra in "$@"; do
    psql -q -v ON_ERROR_STOP=1 -d "$banco" -f "$extra"
  done
  psql -v ON_ERROR_STOP=1 -d "$banco" -f "$teste"
}

rodar invariantes "$RAIZ/tests/invariantes.sql"
rodar mapa_status "$RAIZ/tests/mapa_status.sql" "$RAIZ/backfill/mapa_status.sql"
rodar agendador   "$RAIZ/tests/agendador.sql"
rodar despacho    "$RAIZ/tests/despacho.sql"
rodar modelos     "$RAIZ/tests/modelos.sql"
rodar agentes     "$RAIZ/tests/agentes.sql"
rodar tenants     "$RAIZ/tests/tenants.sql"
rodar provedores  "$RAIZ/tests/provedores.sql"
rodar webhook     "$RAIZ/tests/webhook.sql"
rodar agendamento "$RAIZ/tests/agendamento.sql"
rodar ingestao    "$RAIZ/tests/ingestao.sql"
rodar previa      "$RAIZ/tests/previa.sql"

# ---------------------------------------------------------------------------
# Adapters de canal — TypeScript, sem rede (fetch injetado).
# ---------------------------------------------------------------------------
echo ""
echo "→ adapters de canal (TypeScript)"
node --experimental-strip-types --test "$RAIZ/tests/adapters.test.ts" \
  | grep -E "^# (tests|pass|fail)|^not ok"

echo ""
echo "→ motor: despachante e webhooks (TypeScript)"
node --experimental-strip-types --test "$RAIZ/tests/motor.test.ts" \
  | grep -E "^# (tests|pass|fail)|^not ok"

echo ""
echo "→ fontes de contato: CSV, dialetos e PlanilhaSource (TypeScript)"
node --experimental-strip-types --test "$RAIZ/tests/fontes.test.ts" \
  | grep -E "^# (tests|pass|fail)|^not ok"

# ---------------------------------------------------------------------------
# A fronteira. Os testes acima trabalham com cópias — o de TypeScript repete
# as expressões da trava, o de SQL usa identidades escritas à mão. Aqui a
# saída real da PlanilhaSource entra pela `ingerir_contato` real, que é o par
# que roda em produção.
# ---------------------------------------------------------------------------
echo ""
echo "→ planilha ponta a ponta (PlanilhaSource → ingerir_contato)"
BANCO_FONTE="$(novo_banco fonte)"
node --experimental-strip-types "$RAIZ/tests/planilha_para_sql.ts" \
  | psql -v ON_ERROR_STOP=1 -d "$BANCO_FONTE" -f -

# ---------------------------------------------------------------------------
# Concorrência: o agendador precisa de SKIP LOCKED de verdade, não só no texto
# da função. Duas sessões simultâneas têm que pegar lotes disjuntos.
# ---------------------------------------------------------------------------
echo ""
echo "→ concorrência do agendador (SKIP LOCKED)"
BANCO_CONC="$(novo_banco concorrencia)"

psql -q -v ON_ERROR_STOP=1 -d "$BANCO_CONC" <<'SQL'
INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('cc000000-0000-0000-0000-000000000001','Conc','morna','opt-in','{whatsapp}');
INSERT INTO flows (id, nome) VALUES ('cc000000-0000-0000-0000-000000000002','Conc');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES ('cc000000-0000-0000-0000-000000000003','cc000000-0000-0000-0000-000000000002',1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
VALUES ('cc000000-0000-0000-0000-000000000003',1,'whatsapp',0,'oi');
DO $$
DECLARE v uuid;
BEGIN
  FOR i IN 1..3 LOOP
    v := gen_random_uuid();
    INSERT INTO contacts (id, nome, origem) VALUES (v, 'C'||i, 'planilha');
    INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
    VALUES (v,'whatsapp','+5515900000'||i,'5515900000'||i,'planilha');
    PERFORM inscrever(v,'cc000000-0000-0000-0000-000000000001',
                      'cc000000-0000-0000-0000-000000000003', now() - interval '1 minute');
  END LOOP;
END;
$$;
SQL

TOTAL=$(psql -tA -d "$BANCO_CONC" -c "SELECT count(*) FROM proximos_vencidos(100)")

# Sessão A segura o primeiro vencido dentro de uma transação aberta.
psql -q -o /dev/null -d "$BANCO_CONC" \
  -c "BEGIN; SELECT * FROM proximos_vencidos(1); SELECT pg_sleep(4); COMMIT;" &
SESSAO_A=$!

# Espera a sessão A pegar a trava (pg_sleep, não sleep de shell).
psql -tAq -o /dev/null -d "$BANCO_CONC" -c "SELECT pg_sleep(1)"

RESTANTE=$(psql -tA -d "$BANCO_CONC" -c "SELECT count(*) FROM proximos_vencidos(100)")
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
BANCO_DOWN="$(novo_banco reversibilidade)"

for d in $(ls -r "$RAIZ"/supabase/down/*.sql); do
  psql -q -v ON_ERROR_STOP=1 -d "$BANCO_DOWN" -f "$d"
done

RESTOS=$(psql -tA -d "$BANCO_DOWN" -c "
  SELECT (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')
       + (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
           WHERE n.nspname = 'public' AND t.typtype = 'e')
       -- Schema criado por migration também é resto: 'privado' tem que sumir.
       + (SELECT count(*) FROM pg_namespace WHERE nspname = 'privado');")

if [ "$RESTOS" -eq 0 ]; then
  echo "PASS  migrations revertem sem deixar tabela nem tipo para trás"
else
  echo "FALHA down deixou $RESTOS objeto(s) no schema public"
  psql -d "$BANCO_DOWN" -c "SELECT tablename FROM pg_tables WHERE schemaname='public'"
  exit 1
fi

for m in "$RAIZ"/supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -d "$BANCO_DOWN" -f "$m"
done
echo "PASS  migrations reaplicam limpas após o down"

echo ""
echo "Tudo verde."
