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
adapters/              ChannelAdapter por provedor (TypeScript, sem I/O de runtime)
motor/                 despachante e webhooks — lógica pura, banco atrás de uma porta
supabase/functions/    edge functions: só fiação, a única camada sem teste
demo/                  cenário de demonstração: roda o motor e exporta o que ele decidiu
ui/                    console de operação (protótipo), alimentado pela saída do demo
backfill/              ferramentas da migração de dados (fora do schema de runtime)
tests/                 suite — um banco descartável por arquivo
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

## O agendador

`processar_vencidos(limite, modo)` é uma passada do worker: acorda, pergunta quem está vencido,
decide e reivindica o passo. **Não envia** — o adapter da Fase 1 consome `messages` com status
`pendente`. Por isso o shadow mode não depende de adapter nenhum: é o mesmo código gravando
`simulado`.

A decisão vive em SQL porque precisa ser atômica com a reivindicação do passo. Separar o `SELECT`
do `INSERT` entre processos reabriria a janela de corrida que a invariante 1 fecha.

Cada passada devolve o que fez em cada enrollment, para o shadow mode ser comparado passo a passo
em vez de por total:

| Ação | Quando |
|---|---|
| `mensagem_criada` | Passo reivindicado e mensagem gravada |
| `encerrado_fim` | Não há próximo passo |
| `encerrado_supressao` | Contato entrou na supressão depois de inscrito |
| `passo_pulado_canal` | Canal do passo não está habilitado na campanha |
| `passo_pulado_sem_identidade` | Contato não tem endereço nesse canal |
| `passo_pulado_identidade_suprimida` | Endereço suprimido — inutiliza o canal, não a pessoa |
| `adiado_sem_remetente` | Pool vazio ou quota estourada: adia sem consumir o passo |
| `passo_ja_reivindicado` | Outro worker chegou antes (invariante 1 funcionando) |
| `ignorado_campanha_inativa` | Campanha desligada segura a cadência sem encerrar ninguém |

A quota é reservada nos dois modos de propósito: o shadow mode existe para mostrar o que o motor
faria, e o que ele faria inclui ser freado pelo rate limit.

## Adapters de canal

`adapters/` implementa `ChannelAdapter` (`send`, `normalizeWebhook`, `checkHealth`). O motor já
decidiu identidade, remetente e conteúdo antes de chegar aqui — o adapter só fala o dialeto do
provedor.

| Provedor | Canal | Migra de |
|---|---|---|
| `evolution` | whatsapp (não-oficial) | `send-evolution-message` + `evolution-webhook` |
| `meta_cloud` | whatsapp (oficial) | `meta-send-via-bsp` + `meta-webhook` |
| `comtele` | sms | `comtele-send-sms` |

E-mail e Instagram ainda não têm adapter, e o registro **declara isso** em
`PROVEDORES_POR_CANAL` — melhor do que descobrir em produção.

Três regras que valem para qualquer adapter novo:

- **Nenhuma API específica de runtime.** Só `fetch` e tipos web, e `fetch` é injetado pelo
  construtor. O mesmo arquivo roda no Deno das edge functions e no Node dos testes, e nenhum teste
  toca a rede.
- **Segredo entra por parâmetro.** O adapter nunca lê variável de ambiente nem consulta o banco; o
  chamador resolve do Vault.
- **Toda falha diz de quem é a culpa** (`remetente`, `destino`, `transitorio`). Só `remetente`
  alimenta o circuit breaker — derrubar uma conta boa por causa de um número inválido esvazia o
  pool sem motivo.

Rodam com `node --experimental-strip-types --test tests/adapters.test.ts`, ou junto da suite.

## O worker

`motor-worker` é chamado por cron e faz uma passada: `processar_vencidos` e depois
`despachar`. `canal-webhook/<provedor>` recebe o retorno do provedor, normaliza pelo adapter e
grava eventos.

As duas edge functions são finas de propósito. Toda decisão vive em `motor/`, que fala com o banco
por uma porta (`motor/porta.ts`) e por isso é testável sem Supabase, ou no SQL, que é testado
direto. A implementação da porta sobre o supabase-js é a **única camada sem teste automatizado** —
não dá para exercitá-la fora do Supabase, então ela não decide nada.

O modo do worker é `simulado` por padrão. Durante a Fase 3 nenhuma chamada precisa se lembrar de
pedir shadow mode, e ligar o envio real é uma mudança explícita no agendamento do cron.

Duas coisas que o despachante garante e que o legado não garantia:

- **Uma mensagem que explode não derruba o lote.** Cada uma é tratada isolada, e a falha vira
  resultado registrado — não exceção que sobe e deixa as outras presas até o lease vencer.
- **A culpa da falha chega ao banco.** Culpa do destino invalida a identidade e vira fato na
  `outbox` (D3); culpa do remetente e falha transitória penalizam a conta. Sem essa distinção,
  uma lista suja abriria o circuito de remetentes saudáveis — o oposto da invariante 3.

## Modelos de campanha

`campaign_templates` é o catálogo do hub: sete receitas prontas (resgate por WhatsApp, resgate
multicanal, direct no Instagram, renovação de apólice, reengajamento, prospecção fria em um ou
dois canais), cada uma com cadência, base legal e canais que sabe usar.

`criar_campanha_de_modelo(slug, nome, canais)` instancia: cria campanha, flow, versão 1 e passos.
Os canais escolhidos filtram a cadência — passo de canal não escolhido sai, e os que restam são
renumerados com o primeiro saindo na hora.

Modelo **não** é campanha. Como `flow_versions` é imutável (D9), editar o modelo depois não mexe
em nenhuma campanha já criada — há teste para isso.

Recusa na criação, em vez de descobrir em produção: canal que o modelo não conhece, modelo inativo,
e combinação de canais que deixaria a cadência sem nenhum passo.

## Agentes e provedores de IA

`agents` é a persona de resposta de **um** canal. `campaign_agents` amarra um agente por canal
habilitado da campanha — chave primária `(campaign_id, canal)`, porque dois agentes no mesmo
WhatsApp da mesma campanha seriam duas pessoas respondendo o mesmo contato.

A fronteira (D16): o motor é dono da cadência, o agente é dono da conversa. Quando a pessoa
responde, o enrollment encerra e o agente assume. Agente não acelera passo nem troca canal —
há teste verificando que nenhuma tabela do motor referencia agente.

`ai_provider_catalog` descreve, por provedor, os campos que ele precisa. A tela de configuração se
monta a partir disso e não conhece provedor nenhum; provedor novo é uma linha no catálogo.

**O segredo é verificado pelo banco.** O catálogo marca quais campos são segredo, e um trigger
recusa gravar qualquer um deles em `config`. Não existe coluna para a chave — só `chave_secret_id`
apontando para o Vault. A anti-regra deixou de depender de disciplina.

## Multi-tenant e RLS

O produto nasce multi-cliente. Não há modo "um cliente só" que depois vira multi — isso é reescrita
de schema com dados dentro. `tenant_id` está em toda tabela de domínio desde agora.

Três camadas, e nenhuma confia na de cima:

1. **`tenant_id` em toda tabela de domínio.** Quem esquecer de filtrar não passa da camada 2.
2. **Chaves estrangeiras compostas `(tenant_id, id)`.** Um enrollment do cliente A não consegue
   apontar para a campanha do cliente B nem por bug de aplicação — o banco recusa com `23503`,
   mesmo como superusuário, onde RLS nem entra em cena.
3. **RLS por tenant, com papel decidindo escrita.** `dono` e `admin` administram, `operador` opera,
   `leitor` lê. As credenciais de IA só são visíveis para quem administra.

Papéis ficam em `tenant_users (tenant_id, user_id, papel)`. As políticas chamam
`pertence_ao_tenant()`, `pode_operar()` e `pode_administrar()`, todas `SECURITY DEFINER` — a política
de `tenant_users` não pode consultar `tenant_users` sob RLS, seria recursão.

**Supressão é por cliente, não global.** O mesmo telefone pode estar na base de dois clientes; o
opt-out dado a um não é um fato do outro. `esta_suprimido()` recebe o tenant como primeiro argumento.

**O catálogo é compartilhado.** `campaign_templates` e `agents` com `tenant_id IS NULL` são do
sistema e todo cliente enxerga. Usar um agente do catálogo **copia** a linha para o tenant na
primeira atribuição, então editar a persona não mexe no catálogo nem nos outros clientes.

`tests/tenants.sql` é o que sustenta a afirmação "pode ser vendido": 32 asserções que entram na pele
de usuários de dois clientes diferentes. Os testes de negação conferem o **SQLSTATE**, não só que
deu erro — `42501` é o RLS recusando, `23503` é a chave composta, `23001` é o gatilho de coerência
entre agente e campanha. Um teste que só olha "levantou exceção" também passa com um typo no nome
da coluna.

## Console de operação

`demo/gerar.sh` cria duas campanhas **a partir dos modelos**, roda o motor sobre sete contatos,
avança o relógio de evento em evento e exporta tudo que ele decidiu para `demo/preview.json`.
`ui/console.html` lê esse arquivo.

A tela tem duas partes. O **hub** é a inicial: métricas agregadas, cards das campanhas em operação,
catálogo de modelos e o assistente de criação — que mostra quais canais têm adapter hoje e quais
não têm, em vez de oferecer tudo e falhar depois. O **console** é o detalhe de uma campanha, com a
régua temporal que reproduz as horas simuladas.

Não é mockup: os números, as mensagens e as decisões são do motor real. O provedor é simulado
dentro do `demo/preview.sql` — em produção quem responde é o adapter.

A régua é o ponto. O que distingue este motor de um disparador é que o estado vive no contato e a
execução acontece ao longo do tempo; um painel de totais não mostra isso, e é justamente aí que
mora a pergunta de operação quando algo dá errado — o que o motor decidiu, e quando.

É protótipo de tela, não o produto: não cria campanha, não edita flow, não sobe planilha e não tem
autenticação.

## Convenção

Teste vermelho é bloqueio, não aviso. Toda mudança de schema roda `tests/run.sh` antes do commit.

Cada arquivo de teste roda em banco próprio. Compartilhar banco já produziu duas falhas falsas
aqui — uma por remetente ambíguo entre fixtures, outra por mensagem pendente alheia.
