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
   A checagem acontece no roteador, antes do adapter — não dentro de cada adapter. E **de novo no
   despacho** (D39): entre criar a mensagem e mandá-la existe uma janela, e quem pede para sair
   dentro dela também não recebe. Mensagem assim vira `cancelado`, não `falha`.
3. **Rate limit por remetente.** Nenhum `sender_account` ultrapassa sua quota. Conta com erro sai do
   pool sozinha (circuit breaker), e os pendentes rebalanceiam — o que exige duas coisas, não uma:
   `remetentes_disponiveis` deixa de oferecê-la às mensagens **futuras**, e `reivindicar_pendentes`
   troca o remetente das que **já existem** (D37).
4. **Encerramento global.** Resposta em qualquer canal encerra o enrollment inteiro, não só o passo
   — inclusive a mensagem que já estava na fila esperando despacho (D40). Encerrar a cadência e
   mandar mais um toque é a invariante furada pela borda.

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
- **Nunca** criar tabela de domínio sem `tenant_id`, nem chave estrangeira entre tabelas de domínio
  que não seja composta `(tenant_id, id)`. RLS não alcança o worker, que roda com service key.
- **Nunca** deixar tenant implícito em assinatura de função. É como bug entre clientes acontece.
- **Nunca** criar função em `public` que não seja API de verdade. `public` é publicado pelo PostgREST;
  RLS, gatilhos e motor moram em `privado`. Função nova não nasce com EXECUTE — conceder é decisão.
- **Nunca** adicionar `privado` aos *Exposed schemas* do projeto. É o que separa motor de endpoint.
- **Nunca** cadastrar remetente com provedor fora de `channel_provider_catalog`, nem gravar em
  `sender_accounts.config` um campo que o catálogo marca como segredo. Segredo vai para o Vault.
- **Nunca** deixar uma tela de Configurações ou Canais expandida por padrão. Grupo abre índice,
  não conteúdo (D21).
- **Nunca** receber webhook num endpoint que não identifique o chip. Sem chip não há tenant, e sem
  tenant casar resposta pelo número encerra a cadência do cliente errado (D24).
- **Nunca** exigir o painel do Supabase para configurar o produto. Segredo entra pela tela, por
  `salvar_servidor_provedor` / `salvar_credencial_remetente` (D26).
- **Nunca** misturar provedor oficial e não oficial na mesma tela. Mudam base contratual, risco de
  banimento e pool permitido — misturar é como campanha institucional acaba num chip frio (D27).
- **Nunca** deixar a tela decidir o que é segredo. Quem separa Vault de `config` é o catálogo,
  dentro da função — a UI manda o que foi preenchido e não conhece provedor nenhum (D28).
- **Nunca** escrever segredo no comando de um job do `pg_cron`. `cron.job` é tabela comum: vai para
  backup, réplica e `pg_dump`. A chave fica no Vault e é lida na batida (D29).
- **Nunca** abrir exceção de runtime em `adapters/`. Ali só entra `fetch` — é o que faz o mesmo
  arquivo rodar no Deno da edge function e no Node do teste. Provedor que exige socket não vira
  adapter; vira linha de catálogo com `tem_adapter = false` (D30).
- **Nunca** devolver `culpa = 'destino'` por erro que não é do contato. Isso invalida
  `contact_identities` e escreve `identidade_invalida` no CRM. Domínio não verificado e chave sem
  permissão são culpa do remetente (D30).
- **Nunca** deixar o roteador prometer um envio que o despachante não tem como fazer. Coluna de
  catálogo que ninguém lê não é garantia: o pool pergunta `tem_adapter` e `ativo` antes de escolher,
  e sem candidato o passo é adiado, nunca queimado (D31).
- **Nunca** normalizar identidade em dois lugares. Quem normaliza é `adapters/telefone.ts`,
  `adapters/email.ts` e `adapters/instagram.ts`; o banco **confere** (`privado.normalizada`). Duas
  normalizações divergentes é, literalmente, como a supressão fica furada (D32).
- **Nunca** fundir contatos numa importação. Identidades de uma linha que já pertencem a pessoas
  diferentes param a importação; fundir é destrutivo e é decisão de operação (D32).
- **Nunca** deixar a ingestão prometer um canal que o número não tem. Coluna genérica de telefone só
  vira WhatsApp quando é celular — fixo não vira identidade nenhuma, porque prometê-lo é o roteador
  escolhendo um destino que não existe (D33).
- **Nunca** descartar em silêncio um valor que parecia identidade. Linha aceita com telefone ruim
  sai em `ignorados` com coluna, valor e motivo: o contato entrar sem que ninguém saiba que o
  telefone se perdeu é pior do que a recusa (D33).
- **Nunca** gravar importação sem prévia. `prever_ingestao` diz o que aconteceria sem escrever nada,
  e a trava recusa a *chamada* inteira — uma linha ruim no meio de 500 mata a importação (D34).
- **Nunca** converter com cast um valor que veio do cliente dentro da prévia. Cast inválido aborta a
  prévia toda, que é justamente o que ela existe para evitar: casa contra os rótulos do enum e
  recusa só a linha (D34).
- **Nunca** copiar código de `adapters/` para dentro de `app/`. O app importa por alias; cópia é a
  segunda normalização do D32, e a divergência aparece em supressão furada, não em teste (D34).
- **Nunca** confiar que `node --experimental-strip-types` confere tipo. Ele **apaga** o tipo. Quem
  confere é o `tsc` do `tsconfig.json` da raiz, que `tests/run.sh` roda — foi ele que achou oito
  erros que o motor carregava sem saber (D34).
- **Nunca** inscrever em lote sem prévia. Inscrever sem identidade no canal dos passos **não dá
  erro**: o motor pula passo a passo e encerra como concluído sem mandar nada. Silêncio é pior que
  exceção (D35).
- **Nunca** contar `array_length` de `array_agg` sobre junção externa sem `FILTER`. Sem par, o
  agregado vira `{NULL}` e "nenhum" passa por "um" — foi assim que a prévia quase repetiu o
  silêncio que existe para quebrar (D35).
- **Nunca** deixar o shadow mode invisível. Ele roda o caminho inteiro e não envia; sem tela que
  diga "todas em shadow mode", o modo que de-risca o projeto parece defeito (D36).
- **Nunca** rotular ausência de remetente como shadow mode. Em `simulado` o motor **escolhe e
  reserva** remetente igual — quem diz que nada saiu é o `status` da mensagem (D36).
- **Nunca** escrever asserção que o cenário não consegue violar. Teto de 500 com três linhas no
  banco passa com e sem o teto — é o `tem_adapter` do D31 outra vez (D36).
- **Nunca** supor que tirar a conta do pool move as mensagens que já existem. `remetentes_disponiveis`
  decide o **futuro**; a mensagem pendente carrega o remetente na linha, e quem a move é
  `reivindicar_pendentes` (D37).
- **Nunca** devolver a reserva de quota de um envio que não se sabe se saiu. Contar a mais aperta o
  envio; contar a menos fura a invariante 3 (D37).
- **Nunca** casar evento de provedor sem o chip. `provider_message_id` é do provedor e pode repetir
  entre clientes; sem o tenant do chip, `respondido` encerra a cadência de quem não respondeu (D38).
- **Nunca** pôr `EXCEPTION` em volta de um bloco de asserções. Quando dispara, ele desfaz as
  asserções que já tinham passado e o teste encolhe sem avisar (D38).
- **Nunca** chamar a função e conferir o efeito dela na mesma expressão SQL. O `EXISTS` ao lado lê o
  snapshot do início da instrução e não enxerga a linha recém-gravada (D38).
- **Nunca** tratar a supressão como pergunta de uma vez só. O gatilho guarda a criação da mensagem;
  o despacho precisa do seu próprio portão, porque a janela entre um e outro é ilimitada (D39).
- **Nunca** marcar como `falha` uma mensagem que não saiu por opt-out. Opt-out honrado não é defeito
  do motor nem da conta que ia enviar — é `cancelado` (D39).
- **Nunca** deixar o despachante discordar do agendador sobre o mesmo fato. Se `processar_vencidos`
  pula campanha inativa e enrollment encerrado, `reivindicar_pendentes` também pula (D40).
- **Nunca** filtrar despacho por "enrollment ativo". O último passo de toda cadência encerra o
  enrollment na mesma passada que cria a mensagem: o filtro mataria o último toque de todas as
  campanhas. O que distingue é o **motivo** do encerramento (D40).
- **Nunca** cancelar por parada que volta atrás. Pausa e campanha desligada seguram a mensagem;
  cancelada não é recriável, porque `(enrollment_id, step_id)` é única (D40).
- **Sempre** perguntar, ao alargar o tempo de vida de um estado: *o que mais assume que ele é
  curto?* O D37 alargou a janela `pendente` e só o D39 e o D40 foram atrás do que ela quebrou.
- **Nunca** criar função em `public` para repetir o que a política de RLS já diz. A tela de
  supressão insere direto; o teste é que passa a rodar no papel de quem usa o produto (D41).
- **Nunca** deixar o shadow mode sem como ler o texto composto. Rodar tudo sem enviar só vale se
  der para ver o que teria sido enviado — senão o erro mais provável, o template errado, passa
  direto pelo modo que existe para pegá-lo (D42).
- **Nunca** remendar o texto de um template por conta própria. Variável vazia deixa rastro
  ("Olá ,"); a tela marca e quem escreveu decide se preenche o dado ou reescreve a frase (D42).
- **Nunca** deixar o demo passar por um portão sem acioná-lo. Cenário que não cria a situação não
  prova nada e não quebra nada — só para de contar, e a tela fica igual à de antes da correção.
  `demo/conferir.py` recusa o `preview.json` que perder uma das situações (D43).
- **Nunca** deduzir, no relato do demo, um fato que o motor não deixou gravado. O rebalanceamento
  acontece dentro de `reivindicar_pendentes` e não deixa rastro em `messages`: ou se fotografa
  antes, ou se está supondo — e supor foi como o demo anunciou quatro trocas que nunca houve (D43).
- **Nunca** deixar um passo manual de configuração sem como conferir antes do efeito. Colar a `anon`
  no lugar da `service_role` agenda, bate e responde 401 — e passada 401 é idêntica a passada sem
  vencidos. Depois de agendado, o erro vira silêncio com cara de normalidade (D44).
- **Nunca** devolver o segredo numa função que o lê. Fatos a respeito dele — papel, projeto,
  validade, tamanho — nunca o valor. E com asserção, porque a distância entre uma coisa e outra é
  uma linha de "debug" esquecida (D44).
- **Nunca** aparar em silêncio a sujeira de um segredo. O worker usa o valor como está: espaço nas
  pontas é defeito a apontar, não a esconder. E `btrim` de um argumento apara só espaço — quebra de
  linha e tabulação passam direto (D44).
- **Nunca** declarar um contrato sem conferir quem o produz. Dos quatro fatos do D3, três nunca
  nasciam — a palavra só existia no enum, e `'respondido'` ainda por cima colidia com um valor de
  `tipo_evento`, o que escondeu a falta (D45).
- **Nunca** deixar o shadow mode escrever no CRM. `simulado` significa caminho inteiro sem efeito
  externo, e o CRM é externo: contar que a campanha concluiu sem nenhuma mensagem ter saído é
  mentira que o backfill não desfaz. O gate é a existência de mensagem não-simulada (D45).
- **Nunca** devolver ao CRM um fato que veio dele. `mudanca_etapa_crm` encerra o enrollment e não
  gera writeback — é o eco que o D3 manda evitar (D45).
- **Nunca** tratar fato da pessoa como fato do enrollment. Resposta encerra todos os enrollments do
  contato; sem índice único, quem está em três campanhas gera três escritas iguais no CRM (D45).
- **Nunca** deixar um fato nascer sem quem o consuma. `tentativas`, `proxima_tentativa_em` e
  `ultimo_erro` existiam desde a primeira migration e nenhum SQL as escrevia — coluna que parece
  garantia e é decoração é o `tem_adapter` do D31 de novo (D46).
- **Nunca** deixar o dreno parado parecer fila vazia. "Zero writebacks saindo" tem duas causas
  opostas, e o único número que as separa é a idade do pendente mais antigo: fila vazia não tem
  mais antigo (D46).
- **Nunca** desistir de um writeback em silêncio. No teto de tentativas o fato nunca chega ao CRM;
  se ninguém puder listar o que desistiu, é o D45 repetido uma camada acima (D46).
- **Nunca** deixar uma linha reivindicada sair de `pendente`. A trava de dedup do D45 é parcial em
  `status = 'pendente'`: tirar a linha de lá enquanto ela está em voo reabre a porta que o D45
  fechou — e libera a trava é o que `falha` faz de propósito, porque o fato não chegou (D46).

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
> A Fase 1 tem seis adapters em `adapters/` (Gupshup, Meta Cloud, UAZAPI, Evolution, Comtele, Resend) com a
> superfície de despacho em SQL (`reivindicar_pendentes`, `registrar_resultado_envio`,
> `registrar_evento_provedor`). O Instagram ainda não tem adapter, e o registro declara isso; `smtp`
> segue no catálogo sem adapter de propósito, porque socket não cabe num diretório que só usa
> `fetch` (D30).
> Cada chip tem a sua URL de webhook (D24), e a UAZAPI cria instância pela própria plataforma (D25).
>
> O worker existe (`supabase/functions/motor-worker`), roda em `simulado` por padrão, e com ele a
> **Fase 3 está completa de ponta a ponta**: agendador, roteador, adapters e despacho rodam sem
> enviar nada.
>
> A **entrada** existe desde o D32: `ingerir_contato` em SQL, `ContactSource` em `adapters/fonte.ts`
> e a primeira implementação em `adapters/planilha.ts`, sobre um leitor de CSV próprio
> (`adapters/csv.ts`) — biblioteca não entra aqui pela mesma regra que vale para os adapters.
> Colher é **puro**: a fonte lê e normaliza, não escreve e não sabe o que é tenant, e é isso que
> torna a prévia da importação possível antes de qualquer gravação (D33).
>
> A **tela de importação** fecha o caminho (D34): lê o arquivo, mostra o que cada coluna virou,
> chama `prever_ingestao` — que diz o que aconteceria sem gravar nada — e só então grava, uma
> chamada por linha. `app/` importa `adapters/` por alias; copiar seria a segunda normalização.
> Puxar `adapters/` para dentro do `tsc` do app revelou que **`adapters/` e `motor/` nunca tinham
> sido checados por tipo**: `--experimental-strip-types` apaga o tipo em vez de conferi-lo. Agora há
> `tsconfig.json` na raiz e `tests/run.sh` roda o `tsc` antes dos testes.
>
> A **tela de contatos** (D35) lista, busca por nome ou número, e inscreve em campanha — também com
> prévia (`prever_inscricao`), porque aqui o erro é silencioso: inscrever quem não tem identidade no
> canal dos passos não dá erro, dá uma campanha "concluída" sem mensagem nenhuma.
>
> A **tela da campanha** (D36) fecha o laço: o que o motor fez, contado no banco
> (`resumo_da_campanha`) e lido de `message_events` (`eventos_da_campanha`). É ela que torna o
> shadow mode legível — sem ela, "rodou tudo e não enviou nada" é igual a "está quebrado".
>
> Falta da Fase 2: o backfill em si, que depende de acesso aos dados do projeto legado
> `gtivnngoeccqbvfjiyne` — e com ele a comparação contra o Disparador.
>
> O schema é **multi-tenant desde a primeira migration** (D18): `tenant_id` em toda tabela de
> domínio, chaves estrangeiras compostas `(tenant_id, id)` e RLS por papel. `tests/tenants.sql`
> entra na pele de dois clientes diferentes e confere o SQLSTATE de cada recusa, e três meta-testes
> **derivados do schema** cobram `tenant_id`, RLS e FK composta de toda tabela nova — lista escrita
> à mão envelhece sem avisar, e essa já tinha perdido a `provider_servers` (D31).
>
> O schema está **aplicado no projeto `hucuwjvihqgftdjpnych`** (32 migrations no repositório, 37
> registros no projeto — duas corretivas de texto, uma separação e duas do D46 (superfície e
> tenant explícito), ver D32, D39 e D46), conferido por
> digest estrutural contra o banco de teste — colunas, constraints, índices, políticas, corpos de
> função e a grade de privilégios batem byte a byte.
>
> Esse "30" tinha ficado em "21" por nove migrations, aqui no arquivo que instrui toda sessão nova.
> É a mesma classe de defeito do parágrafo de cima — número escrito à mão envelhece sem avisar — e
> agora ele é cobrado: `tests/run.sh` conta os arquivos de `supabase/migrations/` e falha se esta
> linha discordar. O do projeto não dá para conferir do suite (precisa de rede), então quem mexer
> no schema confere pelo `list_migrations` junto com o `get_advisors` que já é obrigatório.
>
> As três edge functions estão na **versão 2** no projeto, cada arquivo conferido byte a byte
> contra o repositório depois de publicar. `LIGAR.md` é o procedimento de ligar o motor, com a
> conferência do D44 entre guardar a chave e agendar.
>
> Toda mudança de schema roda `tests/run.sh` antes do commit. Teste vermelho é bloqueio, não aviso.
> Toda mudança aplicada no projeto roda `get_advisors` depois: o suite não enxerga o que só existe
> no Supabase (default privileges, superfície do PostgREST) — foi assim que D19 apareceu.
> O produto roda em `app/` (React + Vite, deploy na Vercel); `ui/console.html` é o protótipo onde
> o design foi decidido e vai morrer quando o app cobrir tudo.
> `demo/gerar.sh` roda o motor num cenário completo, injeta o resultado em `ui/console.html` por
> `demo/injetar.py` e o console mostra — foi assim que D15 apareceu, um erro que teste unitário
> nenhum pegava. O dado do console **não** se cola à mão: colar à mão foi como as constantes de
> canal sumiram do arquivo sem ninguém notar. O cenário encena a janela entre criar a mensagem e
> despachá-la, que é onde o D37, o D39 e o D40 vivem, e `demo/conferir.py` recusa o `preview.json`
> que deixar de acionar qualquer um deles: passar pelo portão não é o mesmo que tocá-lo (D43).

**Fase 0 concluída** — inventário em `INVENTARIO-FASE-0.md`: 83 edge functions e 52 tabelas
classificadas em migra/adapta/descarta. Leitura obrigatória antes de propor qualquer migração de
código antigo; várias suposições do `DECISOES.md` foram corrigidas lá (em especial: UAZAPI não
existia na base, e o WhatsApp não-oficial que rodava era Evolution API). **D22 revisou isso:** o
compromisso com UAZAPI existe fora do código, então UAZAPI é o não-oficial de agora e Evolution
continua no catálogo por causa dos chips do legado.

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
| **Supressão** | Lista imutável, **por tenant**, de quem não pode receber nada. Acima de qualquer regra do cliente — e o opt-out dado a um cliente não é fato de outro. |
| **Tenant** | Cliente do produto. Dono dos seus contatos, campanhas, remetentes e agentes. Papéis: dono, admin, operador, leitor. |
