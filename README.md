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
app/                   o produto: React + Vite, falando com o Supabase
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

### A superfície que o PostgREST publica

O Supabase transforma **toda** função de `public` em `/rest/v1/rpc/<nome>`, e toda função nasce
com EXECUTE para `PUBLIC` — mais os grants nominais a `anon` e `authenticated` que o projeto instala
por `ALTER DEFAULT PRIVILEGES`. Sem cuidado, cada engrenagem do motor vira endpoint aberto.

A separação é por schema, porque schema é o que o PostgREST enxerga:

| | Conteúdo | Quem chama |
|---|---|---|
| `public` | tabelas e as 10 funções que são API de verdade | worker (`service_role`) e UI (`authenticated`), nominalmente |
| `privado` | RLS, gatilhos e as engrenagens do motor | ninguém de fora — não há endpoint |

`anon` não executa **nada** em `public`. Função nova também não nasce aberta: o default privilege
foi revogado, então virar API é decisão explícita, não esquecimento.

`criar_tenant` tem duas formas. A de dois argumentos é o cadastro self-service e o dono é sempre
`usuario_atual()` — não há como dizer de quem é o tenant. A de três argumentos é administrativa
e só `service_role` alcança. Antes disso havia uma forma só, `SECURITY DEFINER`, com `p_dono` e
aberta a `anon`: qualquer visitante criava tenant em nome de um uuid qualquer.

> Isso não veio de teste local — veio do `get_advisors` do projeto real. O Postgres de teste não
> tem os default privileges do Supabase, então o suite passava com o buraco aberto. Schema certo e
> projeto seguro são duas verificações diferentes.

`tests/tenants.sql` é o que sustenta a afirmação "pode ser vendido": 40 asserções que entram na pele
de usuários de dois clientes diferentes. Os testes de negação conferem o **SQLSTATE**, não só que
deu erro — `42501` é o RLS recusando, `23503` é a chave composta, `23001` é o gatilho de coerência
entre agente e campanha. Um teste que só olha "levantou exceção" também passa com um typo no nome
da coluna.

## Canais e provedores de contato

`channel_provider_catalog` descreve, por canal, cada provedor e os campos que ele precisa — o mesmo
padrão do catálogo de IA. `sender_accounts.provedor` é chave estrangeira para ele, então provedor
inexistente é recusado no cadastro, não na hora do envio.

| Canal | Provedor | Situação |
|---|---|---|
| WhatsApp | **Gupshup** (oficial, BSP) | adapter pronto — é o caminho oficial da operação |
| WhatsApp | Meta Cloud API (oficial, direto) | adapter pronto — alternativa quando a conta já é própria |
| WhatsApp | **UAZAPI** (não oficial) | adapter pronto — é o não-oficial escolhido (D22), campanha fria |
| WhatsApp | Evolution API (não oficial) | adapter pronto — é o que roda no legado; contas novas vão para UAZAPI |
| SMS | Comtele | adapter pronto |
| E-mail | SMTP | declarado sem adapter |
| Instagram | Graph API | declarado sem adapter |

**Múltiplas contas é o caso normal.** Cada app da Gupshup é um `sender_account` com o seu
`app_name`, o seu `source` e o seu segredo no Vault — e por isso o pool, a quota diária e o circuit
breaker (invariante 3) continuam valendo sem nada de novo. Duas contas no mesmo processo não se
confundem porque o app vem da credencial da conta, nunca de constante no adapter; há teste para isso.

**O segredo é verificado pelo banco**, como em `ai_credentials`: o catálogo marca quais campos são
segredo e um gatilho recusa gravá-los em `sender_accounts.config`. Não existe coluna para a chave.

Provedor sem adapter aparece na tela e **não** vira opção de envio: o motor recusa antes de prometer.

### Como a resposta encerra a cadência

Dois caminhos, porque os provedores não são iguais nisso:

| | Quando | Como casa |
|---|---|---|
| Por id | O provedor diz a qual mensagem nossa o evento se refere — oficiais, e toda confirmação de entrega | `provider_message_id` |
| Por número | O provedor não diz. É o caso da resposta nas não oficiais | o chip que recebeu o webhook dá o tenant; o banco acha a última mensagem daquele tenant para aquele número |

**Cada chip tem a sua URL de webhook** (`/canal-webhook/<token>`), e é ela que diz de qual conta o
evento veio. Sem isso não haveria tenant, e casar pelo número escolheria a mensagem de outro
cliente. O token é a credencial: 128 bits aleatórios, um por conta.

O encerramento continua saindo do gatilho de `message_events`. A invariante 4 não ganhou um segundo
caminho — ganhou uma segunda entrada para o mesmo caminho.

## Criar chip pela plataforma

`provider_servers` guarda a URL e o token de administração do provedor (o token no Vault, sem coluna
de texto). A partir dele a plataforma cria a instância sozinha:

1. sorteia o token do webhook
2. cria a instância no provedor **já apontando** para esse endpoint
3. guarda o token da instância no Vault e cria o `sender_account`, numa transação

A ordem importa. Criar primeiro no banco deixaria conta apontando para instância que não existe se o
provedor recusasse; criar sem webhook e apontar depois deixaria uma janela em que a resposta do
contato se perde. No pior caso sobra uma instância órfã no painel do provedor — visível e
descartável, em vez de silenciosa no nosso banco.

O QR volta na resposta e morre ali: guardar QR é guardar credencial de sessão de WhatsApp.

### O que isto consertou

A resposta do contato só encerra o enrollment se o webhook citar a mensagem que o motor mandou —
é por `provider_message_id` que `registrar_evento_provedor` liga as duas pontas. As APIs oficiais
mandam esse `context`; as não oficiais, normalmente não.

O adapter emite `providerMessageId` quando há citação e `deNumero` quando não há — nunca um id
inventado, que gravaria um evento que jamais casa.

**A invariante 4 não valia para resposta sem citação no canal não-oficial**: o contato respondia, o
motor não ficava sabendo e a cadência seguia tocando. Valia o mesmo para Evolution, que emitia o id
da mensagem do contato — um id que nunca casava com `messages`.

Agora vale, pelos dois adapters. `tests/webhook.sql` exercita o caminho inteiro: campanha fria,
primeiro toque, resposta sem citação, enrollment encerrado com motivo `resposta`.

## Configurar provedor

Tudo se configura pelo painel do produto — **nada depende de abrir o dashboard do Supabase**.
`salvar_servidor_provedor`, `salvar_credencial_remetente` e `salvar_credencial_ia` mandam o segredo
para o Vault a partir da tela.

As três são a exceção à regra do D19 (nada com `SECURITY DEFINER` exposto ao usuário logado), porque
escrever no Vault exige isso. Como `SECURITY DEFINER` passa por cima da RLS, a pergunta que a
política faria — `pode_administrar` — é feita **dentro da função**, com teste para operador barrado
e para administrador passando.

Token em branco na edição não apaga o que está guardado: o campo volta vazio porque segredo não é
legível, e tratar vazio como "apagar" derrubaria um servidor que está funcionando.

**A separação entre segredo e `config` é do catálogo, não da tela** (D28). A tela manda tudo o que
foi preenchido num objeto só; a função lê `ai_provider_catalog` / `channel_provider_catalog` e
decide o que vai para o Vault. Pedir à UI que mandasse os dois separados obrigaria ela a saber que
`api_key` é segredo e `base_url` não — e é por não conhecer provedor nenhum que ela sobrevive a um
provedor novo entrar no catálogo.

`segredo_da_credencial_ia`, `segredo_do_remetente` e `segredo_do_servidor` são o caminho de volta, e
não são API: devolvem a chave em texto claro e só o `service_role` chama. O suite confere que
`authenticated` alcança as de escrita e **não** alcança essas.

## Agendar o motor

O motor não é um endpoint que alguém chama — é um worker que acorda e pergunta "quem está vencido
agora?". `pg_cron` faz a pergunta; `pg_net` entrega a batida na edge function e volta na hora, para
que job nenhum fique esperando worker.

A service key **não** entra no comando do job. O jeito que a maioria dos tutoriais ensina é colar a
chave ali dentro, e `cron.job` é uma tabela como outra qualquer: vai para backup, réplica e
`pg_dump`. Aqui a chave fica no Vault e `privado.chave_do_motor()` a lê no instante da chamada (D29).

Guarde o segredo uma vez, em **Project Settings ▸ Vault ▸ New secret**, com o nome exato:

| Nome | Valor |
|---|---|
| `chave_do_motor` | a `service_role` key do projeto |

Pela tela do Vault, não pelo SQL editor — o editor guarda histórico de consulta, e a chave ficaria
lá em texto claro, que é justamente o que esta decisão evita.

Depois, uma linha no SQL editor:

```sql
SELECT privado.agendar_motor(
  'https://<ref>.supabase.co/functions/v1/motor-worker',  -- URL do worker
  '*/5 * * * *',                                          -- de 5 em 5 minutos
  50                                                      -- vencidos por passada
);
```

Reagendar com outra expressão é a operação comum — subir a frequência, baixar no fim de semana — e
por isso a função é idempotente: ela desagenda antes. Duas cópias do mesmo job dobrariam a carga sem
ninguém notar até o rate limit reclamar.

**O corpo não leva `modo`,** e o worker trata a ausência como `simulado`. O motor calcula, roteia e
grava tudo como `simulado` sem enviar nada. Ligar o envio de verdade é decisão de operação — editar
o agendamento — não mudança de código.

Para ver se está rodando, em shadow mode não há sintoma externo nenhum:

```sql
SELECT * FROM privado.ultimas_passadas(10);   -- quando, status, corpo
SELECT jobname, schedule, active FROM cron.job;
SELECT privado.desagendar_motor();            -- parar
```

Sem `ultimas_passadas`, um 401 no worker pareceria exatamente igual a "não havia vencidos".

As cinco funções moram em `privado`, sem EXECUTE para `anon` nem `authenticated`: agendar o motor é
operação da plataforma, não do cliente. Nenhum tenant agenda o motor de ninguém.

## Navegação do console

Configurações e Canais são grupos de submenu, não páginas empilhadas. Abrir um grupo mostra o
índice do que existe dentro; nada nasce expandido (D21).

```
Campanhas
Operação
Canais ▸          WhatsApp ▸   API Oficial        Gupshup, Meta Cloud
                              API não oficial    UAZAPI, Evolution + servidores de instância
                  E-mail · SMS · Instagram
Configurações ▸   Provedores de IA · Agentes · Modelos de conversa · Plataformas de contato
```

**Oficial e não oficial são telas separadas** (D27), e não por organização visual: mudam base
contratual, risco de banimento e qual pool pode usar. Configurar chip de automação e número
homologado na mesma lista é o que faz alguém apontar campanha institucional para um chip frio.

A divisão sai de `channel_provider_catalog.oficial`, então canal que só tem um dos dois — SMS,
e-mail, Instagram — continua com uma tela só, sem submenu vazio.

Cada canal tem a sua tela: contas conectadas, capacidade diária e o formulário de conectar outra —
montado a partir dos `campos` que o provedor declara, então nenhum código de UI conhece Gupshup,
Evolution ou Comtele.

O visual segue a referência de design recebida: **Anek Latin** e **Roboto**, fundo escuro com cards
em carvão, menta para o que deu certo e periwinkle para a série secundária, e o item de menu ativo
como pílula preenchida.

## Console de operação

`demo/gerar.sh` cria duas campanhas **a partir dos modelos**, roda o motor sobre sete contatos,
avança o relógio de evento em evento, exporta tudo que ele decidiu para `demo/preview.json` e
injeta o resultado em `ui/console.html` por `demo/injetar.py`.

O dado do console não se cola à mão. Colar à mão foi exatamente como `CANAIS`, `SIGLA`,
`NOME_CANAL` e `HORAS` sumiram do arquivo sem ninguém notar — o console quebrava com
`ReferenceError` ao abrir Canais, Configurações ou o wizard, e nenhum teste via, porque nenhum
teste abria o console num navegador.
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

## O app

`ui/console.html` é protótipo: um arquivo só, sem servidor, com os dados do demo colados dentro.
Ele nunca vai falar com o Supabase — foi onde o design foi decidido, não onde o produto roda.

`app/` é o produto: React + Vite + TypeScript, falando com o Supabase de verdade.

```bash
cd app
cp .env.example .env.local     # as duas variáveis são públicas por desenho
npm install
npm run dev
```

**A chave `anon` é pública.** Ela vai para o navegador e quem protege o dado é o RLS, não ela. Se o
RLS estiver certo, vazar a chave não dá acesso a nada; se estiver errado, escondê-la não salva. Sem
login, o app enxerga só os dois catálogos (`channel_provider_catalog`, `ai_provider_catalog`), que
têm política `USING (true)` de propósito — o resto exige `pertence_ao_tenant`.

| Caminho | O que faz |
|---|---|
| `src/supabase.ts` | cliente e URL das edge functions |
| `src/sessao.tsx` | sessão, tenants do usuário e papel; troca de cliente |
| `src/dados.ts` | uma função por pergunta. **Nenhuma filtra por tenant à mão** — quem filtra é o RLS |
| `src/telas/Canal.tsx` | contas, servidores, criar instância, conectar conta |
| `src/telas/Telas.tsx` | hub, canais, configurações |

Login é por link no e-mail: não existe senha para vazar nem para o suporte redefinir.

## Deploy na Vercel

O que o repositório já traz pronto: `app/vercel.json` com o *rewrite* de SPA (sem ele,
`/canais/whatsapp/nao` dá 404 ao recarregar), cache imutável nos assets e cabeçalhos de segurança.

O que precisa ser feito uma vez, no painel:

1. **New Project** → importe `afinix-corretora/prospecta`.
2. **Root Directory: `app`.** É o passo que mais se esquece: sem isso a Vercel procura
   `package.json` na raiz e não acha o app.
3. Framework preset **Vite** (a Vercel detecta sozinha depois do passo 2).
4. **Environment Variables**, nos três ambientes (Production, Preview, Development):

   | Nome | Valor |
   |---|---|
   | `VITE_SUPABASE_URL` | `https://hucuwjvihqgftdjpnych.supabase.co` |
   | `VITE_SUPABASE_ANON_KEY` | a chave publishable do projeto |

   `VITE_` é obrigatório no prefixo: o Vite só expõe ao navegador variável com ele.

5. **Deploy.**

Depois do primeiro deploy, no Supabase → **Authentication → URL Configuration**:

- *Site URL*: o domínio de produção.
- *Redirect URLs*: o domínio de produção **e** `https://*-<seu-escopo>.vercel.app` para os previews.
  Sem isso o link de acesso volta para `localhost` e o login de preview não fecha.

### O que não vai para a Vercel

As edge functions e o worker rodam no Supabase, não aqui — `supabase functions deploy`. A Vercel
serve só o front. Isso é de propósito: o worker precisa de `service_role`, e chave de serviço em
função de front é como ela vaza.
