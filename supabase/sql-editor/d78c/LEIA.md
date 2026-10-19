# D78c pelo SQL Editor — backup antes do DROP

O DROP do D78c apaga duas funções que só leem (`respostas_para_rascunhar` e
`respostas_para_o_agente`) e grava uma linha em `supabase_migrations.schema_migrations`.
Nenhuma tabela, linha ou coluna é tocada. O backup que desfaz isso é o script que o
`2_backup.sql` gera a partir do banco vivo — não o Restore do painel, que volta o banco
INTEIRO para a hora do backup e apaga tudo o que o motor gravou depois.

Ordem, cada arquivo inteiro numa execução só do SQL Editor:

1. **`1_retrato.sql`** — somente leitura. Seis linhas: as duas funções, contexto, selo,
   `outras citacoes` e `chamadas`. Se `outras citacoes` não disser `nenhuma`, PARE.
2. **`2_backup.sql`** — somente leitura. Na coluna `script`, botão direito ▸
   *Copy cell content*, e salvar num arquivo fora do banco (`restaurar_d78c.sql`). Esse
   arquivo é o backup: recria as duas funções com corpo, dono e grade, e apaga a linha de
   registro. Ele confere tudo antes do COMMIT, e se a cópia chegar alterada não grava nada.
3. **`3_apagar.modelo.sql`** — o DROP com a guarda. Como está, não apaga nada: tem dois
   marcadores, trocados pelo `selo` do passo 2 e pelo `N` de `soma=N` do passo 1. A guarda
   recusa se algo mudou depois do backup, se alguém ainda cita ou chama as funções, ou se
   algo depende delas.

Para desfazer depois do DROP: rodar o `restaurar_d78c.sql` salvo no passo 2. Voltar o
`motor-worker` a uma versão ≤ v7 exige isso ANTES de publicar.

Testado num Postgres 16 local com as migrations do repositório, `pg_stat_statements`
carregado e o PostgREST de verdade (v12 e v13) chamando como `service_role`; o que cada
passo da guarda não vê está no cabeçalho do `3_apagar.modelo.sql`.
