# Rodar o backfill do legado: pessoas e supressão (D65)

O que esta etapa grava: **contatos, identidades e supressão**. O que ela não grava: cadências,
enrollments, mensagens e eventos. Levar as cadências em curso para o motor exige escolher uma
cadência por campanha antiga, e a prévia diz quantos leads cada uma tinha em curso. Isso fica
para decisão.

Nada aqui lê o legado direto. O dado chega por exportação, feita por quem tem acesso ao projeto
`gtivnngoeccqbvfjiyne`.

## 1. Exportar do legado (quem tem acesso)

Só leitura, as onze tabelas que `backfill/legado.sql` recebe:

```sh
pg_dump "$LEGADO" --data-only --no-owner --no-privileges \
  -t public.contacts -t public.contact_blacklist \
  -t public.rescue_campaigns -t public.rescue_messages -t public.rescue_leads -t public.rescue_message_logs \
  -t public.blast_campaigns -t public.blast_leads -t public.blast_message_logs \
  -t public.broadcast_campaigns -t public.broadcast_recipients \
  > legado.sql
sed -i 's/^COPY public\./COPY legado./' legado.sql
```

O arquivo tem dado pessoal. Ele não entra no repositório, e é apagado depois do passo 5.

## 2. Preparar o banco do projeto

```sh
psql "$PROSPECTA" -v ON_ERROR_STOP=1 -f backfill/mapa_status.sql   # se ainda não existir
psql "$PROSPECTA" -v ON_ERROR_STOP=1 -f backfill/legado.sql
psql "$PROSPECTA" -v ON_ERROR_STOP=1 -f backfill/backfill.sql
psql "$PROSPECTA" -v ON_ERROR_STOP=1 -f legado.sql
```

`legado` e `backfill` **não** entram em *Exposed schemas*.

## 3. Normalizar (o TypeScript, nunca o SQL — D32)

```sh
psql "$PROSPECTA" -At -c "SELECT tipo || chr(9) || bruto FROM legado.brutos" \
  | node --experimental-strip-types backfill/normalizar.ts \
  | psql "$PROSPECTA" -v ON_ERROR_STOP=1
```

## 4. Prévia, ler, e só então gravar

```sql
SELECT * FROM backfill.previa('<tenant>') ORDER BY ordem, item;
```

Linhas para ler antes de seguir:

- **`valores ainda não normalizados`** precisa ser 0.
- **`SEM MAPEAMENTO`** precisa estar ausente. Se aparecer, o status é novo e o mapa
  (`backfill/mapa_status.sql`, D13) precisa de decisão. Gravar se recusa enquanto isso existir.
- **`com cara de celular sem o nono dígito`** e **`a mesma pessoa duas vezes`** mostram o que a
  regra do celular esconde. Esses números entram só como WhatsApp, e a dupla vira duas pessoas.
  Juntar é decisão de operação.
- **`e-mail em mais de uma pessoa`** conta os e-mails que não foram ligados a ninguém.
- **`leads em curso`** é o número que a decisão sobre as cadências precisa.

```sql
SELECT * FROM backfill.gravar('<tenant>') ORDER BY ordem;
SELECT * FROM backfill.conferir('<tenant>');      -- nenhuma linha
SELECT * FROM backfill.recusas;                   -- pessoas que não viraram contato, com motivo
```

`gravar` roda numa transação e pode ser repetido: na segunda vez não cria nem suprime nada.

## 5. Limpar

Só depois do `conferir` vazio e da lista de recusas lida:

```sql
DROP SCHEMA backfill CASCADE;
DROP SCHEMA legado CASCADE;
```

Pelo MCP do Supabase, o `DROP` espera a confirmação de uma pessoa (D63). Ele vai separado de todo o
resto, e com alguém olhando.
