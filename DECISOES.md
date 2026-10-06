# Motor de Prospecção Multicanal — Decisões de Arquitetura

> Documento vivo. Cada decisão registra **o que foi decidido**, **por quê** e **a consequência técnica**.
> Decisão revisada gera entrada nova, não edição da antiga.

---

## Contexto

Evolução da base existente (`sdr-resgate-evolution`, Disparador/Blaster) de **disparador em lote** para
**motor de cadência multicanal com estado por contato**. Atende dois casos de uso: resgate de
oportunidades antigas (base própria) e prospecção em listas frias.

Abordagem: *strangler fig* sobre a codebase atual — o sistema novo nasce ao lado e absorve o antigo.
Não é rewrite.

---

## Decisões tomadas

### D1 — O motor é um serviço autônomo com API própria
**Consequência:** não há join com a base do CRM. O motor obrigatoriamente tem `contacts` e
`contact_identities` próprios. Ganho colateral: pode subir em produção antes do ProfitCare estar
pronto, consumindo Pipefy como fonte e trocando depois sem alterar o motor.

### D2 — Ingestão via adapters de entrada, espelhando os adapters de canal
Fontes na v1: planilha (upload) e CRM com seleção de etapas de origem.
**Consequência:** interface `ContactSource` com implementações `PlanilhaSource`, `PipefySource`,
`ProfitCareSource`. Toda identidade carrega `origem` e `origem_ref`. Dedup acontece na ingestão,
não no envio.

### D3 — Writeback para o CRM, com contrato estreito
O motor escreve de volta um conjunto pequeno e fixo de fatos: `opt_out`, `identidade_invalida`,
`respondeu`, `campanha_concluida`. Nunca sobrescreve campo do qual o CRM é dono.
**Consequência:** exige credencial de escrita; exige marcação de autoria em toda escrita e descarte
dos próprios eventos no webhook de volta (prevenção de loop de eco); writeback vai por **outbox
assíncrona com retry**, nunca inline com o envio.

### D4 — Ambos os casos de uso no mesmo motor; `tipo_campanha` é estrutural
Campanha não é rótulo: carrega base legal, pool de remetentes permitido e canais habilitados.
O roteador consulta o tipo antes de escolher remetente.
**Consequência:** campanha fria nunca sorteia remetente da operação morna nem dispara do domínio
institucional. Isolamento de raio de explosão garantido por schema, não por disciplina operacional.

### D5 — Cutover começa por resgate de base própria
Mesma codebase para os dois, ordem diferente em produção. Base própria erra barato; lista fria
errando custa remetente queimado.

### D6 — WhatsApp nos dois modos, roteado por campanha
Oficial (Cloud API) para base própria com opt-in; não-oficial (UAZAPI) para frio.
**Consequência:** dois adapters, dois pools de remetentes. Separar o Business Manager da operação
oficial do BM que roda anúncios do grupo.

### D7 — Condições de encerramento do enrollment
Encerram: **resposta em qualquer canal**, **mudança de etapa no CRM**, **fim dos passos**.
Não encerra: **clique em link** — registra como evento de engajamento, pode acelerar o próximo
passo ou trocar o canal, mas a cadência continua.
*Justificativa:* clique é curiosidade, não intenção; encerrar por clique descarta o lead que estava
esquentando. **Revisável** — marcado para revisão após os primeiros dados do shadow mode.

### D8 — Cadência linear na v1, ramificada depois
**Consequência:** `flow_steps` já nasce com coluna `condicoes` (JSONB, vazia na v1) para evitar
migração grande depois.

### D9 — Flows editados apenas pelo time técnico; sem construtor visual na v1
Flow vive como configuração versionada no repo.
**Consequência crítica:** `flow_versions` imutáveis. O enrollment aponta para uma **versão**, não
para o flow. Editar um flow cria versão nova; quem já está inscrito termina na versão antiga.

### D10 — Instagram entra apenas na janela legítima de 24h
`InstagramAdapter` implementado via API oficial (resposta a quem iniciou contato).
Cold DM **não** é adapter — é automação de navegador com sessão, fingerprint e manutenção contínua.
Fica como spike paralelo (ver S3), sem bloquear o motor.

### D11 — Banimento tratado como custo previsível, não como acidente
Postura de risco definida. **Consequência de projeto:** isolar raiz de identidade entre canais —
domínios de prospecção separados do institucional, BM separado do BM de anúncios, chips como
recurso descartável com custo unitário conhecido e health score no pool.

### D12 — Schema antes dos adapters; inverte a ordem das Fases 1 e 2
A ordem original punha `ChannelAdapter` antes do schema novo. Invertido após o inventário da Fase 0.
*Justificativa:* as quatro invariantes são garantidas por schema — chave única `(enrollment_id,
step_id)`, índice parcial em `next_run_at`, gate de supressão, quota por remetente. Schema errado
custa migration em dado de produção; adapter errado custa uma classe. Além disso a Fase 0 mostrou
que a Fase 1 é bem maior do que se supunha (5 caminhos de saída e 7 de entrada, não 3 clientes),
então deixá-la depois evita bloquear o resto.
**Consequência:** o schema central nasce com teste automatizado das invariantes (`tests/run.sh`)
antes de existir qualquer código de envio. O motor não envia nada até a Fase 1 — o que é aceitável,
porque shadow mode (`status = 'simulado'`) já é caminho de primeira classe no schema.

### D13 — Mapa de status legado: quatro escolhas que o backfill precisava
Tomadas ao fechar `MAPA-STATUS.md`, antes de qualquer linha migrada.

1. **`reengaging` vira enrollment novo** em campanha de reengajamento. O modelo novo não tem camadas.
2. **`waiting_cycle` encerra e reinscreve**, em vez de manter um enrollment vivo com o passo zerado.
3. **`cancelado_operacional` entra no enum** `motivo_encerramento`. Decisão humana não é falha do
   motor, e o relatório precisa distinguir.
4. **Supressão migrada alcança a pessoa**, todos os canais — e `discarded` sem metadado é tratado
   como opt-out.

*Justificativa da 4, que é a de maior consequência:* `blast_leads.status = 'discarded'` é gravado
por dois caminhos opostos — opt-out detectado pelo `evolution-webhook` (com `discarded_reason` e
inserção em `contact_blacklist`) e descarte manual pelo operador (sem metadado). Colapsar os dois
num destino só faria quem pediu para sair voltar a ser elegível, quebrando a invariante 2 no
primeiro dia de produção, com registro de que a pessoa pediu para sair.

**Consequência:** o mapa deixa de ser prosa e vira `backfill/mapa_status.sql`, coberto por
`tests/mapa_status.sql` nos 27 valores legados. Status sem mapeamento derruba o backfill em vez de
virar estado inventado. A migration `20260916140000` acrescenta o valor do item 3.

### D14 — O WhatsApp não-oficial é Evolution API, não UAZAPI
Revisa a premissa de D6, que supunha UAZAPI para o modo frio.
*Evidência:* busca por `uaz` nos quatro repositórios não retorna nenhuma ocorrência em código.
O não-oficial que roda hoje é Evolution API self-hosted (`evolutionapi.grupoafx.com.br`), com
cliente completo em `send-evolution-message` e webhook em `evolution-webhook`.
**Consequência:** `WhatsAppEvolutionAdapter` é o adapter do modo frio, e o cliente UAZAPI que o
"o que sobrevive da codebase atual" listava como "migra quase intacto" não existe para migrar.
O spike S1 muda de objeto: medir queima do pool Evolution atual, com dados de produção que já
existem, em vez de um experimento de duas semanas com UAZAPI.
**Reversível a custo baixo:** a interface `ChannelAdapter` não conhece provedor. Adotar UAZAPI
depois é uma classe nova no `adapters/` e uma linha no registro — nada no motor muda.
**Revisada por D22:** o compromisso existe, e UAZAPI passou a ser o não-oficial.
*Confirmar com o time comercial se há compromisso contratual com UAZAPI que eu não enxergo pelo
código.*

### D15 — Adiamento espera a capacidade voltar, não um intervalo fixo
Quando o pool não tem vaga, o agendador reagenda para quando a capacidade pode voltar:
virada da janela diária se a quota esgotou, fim do prazo se o circuito está aberto, uma hora se não
há remetente cadastrado.
*Como apareceu:* o cenário de `demo/` mostrou um chip frio com quota de 2/dia esgotando na terceira
hora e o motor adiando o mesmo contato de 15 em 15 minutos até o fim — 36 tentativas sem chance de
dar certo. Nenhum teste tinha pego, porque cada adiamento isolado estava correto.
**Consequência:** `proximo_horario_de_pool(canal, tipo)` é a fonte dessa resposta, e o cenário
passou de 105 horas com 36 adiamentos perdidos para 5 dias com zero.

### D16 — Agente é dono da conversa; motor é dono da cadência
Cada canal de uma campanha pode ter um agente de IA como persona de resposta. O motor decide
quando tocar e por onde; quando a pessoa responde, o enrollment encerra (invariante 4) e o agente
assume a conversa dali.
*Justificativa:* o agente não acelera passo, não troca canal e não reescreve cadência. Se fizesse,
haveria dois donos do mesmo estado — e o inventário da Fase 0 mostrou o custo disso no legado, onde
`nina-orchestrator` e os motores de disparo disputavam o mesmo lead.
**Consequência:** `agents` tem canal obrigatório, e `campaign_agents` tem chave primária
`(campaign_id, canal)` — uma persona por canal por campanha. Nenhuma tabela do motor
(`enrollments`, `messages`, `flow_steps`) referencia agente; há teste que verifica isso.
Agente de Instagram não atende WhatsApp: janela de resposta, tom e tamanho de mensagem são
diferentes, e o trigger recusa.

### D17 — Provedor de IA é catálogo, não enum
`ai_provider_catalog` guarda, por provedor, os campos que ele precisa. A tela de configuração se
monta a partir disso — escolher OpenAI mostra API key, organização e base URL; escolher Anthropic
mostra API key e base URL; e nenhum código de UI conhece provedor nenhum.
*Justificativa:* provedor novo é uma linha no catálogo, não um deploy de front.
**Consequência crítica:** o catálogo marca quais campos são segredo, e um trigger em
`ai_credentials` **recusa** gravar qualquer um deles em `config`. Não existe coluna para a chave —
só `chave_secret_id` apontando para o Vault. A anti-regra "nunca colocar secret fora do Vault"
deixa de depender de disciplina e passa a ser verificada pelo banco, com teste.
Lista de modelos é sugestão, não enum: catálogo de modelo muda toda semana e lista fixa envelhece.

### D18 — Multi-tenant desde a primeira migration, em três camadas
`tenant_id` em toda tabela de domínio, chaves estrangeiras **compostas** `(tenant_id, id)`, e RLS
por tenant com papel decidindo escrita (`dono`, `admin`, `operador`, `leitor`).
*Justificativa:* não existe "começa com um cliente e depois vira multi". Adicionar `tenant_id` a
tabelas com dados dentro é backfill com janela de inconsistência em cima de um sistema que já
manda mensagem para gente real. Custa quase nada agora e é reescrita depois.
**Por que três camadas e não só RLS:** RLS protege o que passa pelo PostgREST com um JWT. O worker
roda com a service key e RLS não o alcança — é a chave composta que impede um enrollment do cliente
A apontar para a campanha do cliente B, e ela vale inclusive para superusuário. As camadas cobrem
buracos diferentes; nenhuma confia na de cima.
**Consequências:**
- Supressão é por cliente. O mesmo telefone pode estar na base de dois clientes, e o opt-out dado a
  um não é um fato do outro. `esta_suprimido()` recebe o tenant como primeiro argumento.
- Tenant é sempre explícito em chamada de função. `criar_campanha_de_modelo()` perdeu a sobrecarga
  curta: tenant implícito em função é exatamente como bug entre clientes acontece.
- Catálogo (`campaign_templates` e `agents` com `tenant_id IS NULL`) é compartilhado e imutável para
  o cliente. Atribuir um agente do catálogo **copia** a linha para o tenant — editar a persona não
  vaza para os outros clientes.
- Teste de negação confere SQLSTATE, não só que deu erro: `42501` (RLS), `23503` (chave composta),
  `23001` (gatilho agente/campanha). "Levantou exceção" também é o que um typo faz.

### D19 — `public` é API; o motor mora em `privado`
O PostgREST publica toda função de `public` como `/rest/v1/rpc/<nome>`. Ficam em `public` apenas as
10 funções que alguém de fora chama de verdade; RLS, gatilhos e engrenagens do motor vão para o
schema `privado`, que não está em *Exposed schemas*.
*Justificativa:* a alternativa — revogar EXECUTE e manter tudo em `public` — **não funciona**:
expressão de política RLS e corpo de função de gatilho passam pela checagem de EXECUTE do papel que
está escrevendo, então revogar de `PUBLIC` derruba o RLS e os gatilhos. Testado, não deduzido.
**Consequências:**
- `anon` não executa nada em `public`. O default privilege que o Supabase instala foi revogado, então
  função nova não vira endpoint por esquecimento — virar API é decisão explícita.
- `criar_tenant` virou duas: a self-service (dois argumentos, dono é sempre quem está logado) e a
  administrativa (três argumentos, só `service_role`). A forma antiga, `SECURITY DEFINER` com
  `p_dono` e aberta a `anon`, deixava qualquer visitante criar tenant em nome de um uuid arbitrário.
- Toda função tem `search_path` fixo: sem isso, `SECURITY DEFINER` é escalada de privilégio.
**De onde veio:** do `get_advisors` do projeto real, não do suite. O Postgres de teste não tem os
default privileges do Supabase — o suite passava com o buraco aberto. Ficou uma asserção que pega a
regressão (`pg_default_acl` sem `anon`/`authenticated`), mas o advisor continua sendo a checagem que
enxerga o que só existe no projeto.

### D20 — Provedor de canal é catálogo; Gupshup é o WhatsApp oficial
`channel_provider_catalog` descreve, por canal, cada provedor e os campos que ele precisa —
o mesmo padrão do D17 para IA. `sender_accounts.provedor` passa a ser chave estrangeira para ele.
*Justificativa:* `provedor` era texto livre, com um comentário dizendo que um CHECK obrigaria
migration a cada provedor novo. O comentário estava certo sobre o CHECK e errado sobre a conclusão:
quem evita migration é catálogo, não texto solto. Com texto solto, um typo vira remetente que o
despachante não sabe construir — e isso só aparece na hora do envio.
**Escolhas de provedor:**
- **WhatsApp oficial: Gupshup** (BSP homologada), com adapter em `adapters/whatsapp-gupshup.ts`.
  Múltiplas contas e múltiplas apps convivem: cada app é um `sender_account` com o seu `app_name`,
  o seu `source` e o seu segredo no Vault. Por isso o pool e a quota por remetente (invariante 3)
  continuam valendo sem nada de novo. Meta Cloud fica no catálogo como alternativa direta.
- **WhatsApp não oficial: Evolution API** — automação sem homologação, para campanha fria, longe do
  número institucional (D4). É o que existe na base, conforme D14.
- **SMS: Comtele**, adapter já pronto.
- SMTP e Instagram entram no catálogo declarados **sem adapter**: aparecem na tela, não viram opção
  de envio. O motor recusa antes de prometer.
**Consequência:** a tela de conectar conta se monta a partir de `campos`, então nenhum código de UI
conhece Gupshup, Evolution ou Comtele. E o que o catálogo marca como segredo é recusado em
`sender_accounts.config` por gatilho — a mesma garantia de `ai_credentials`.

### D21 — Tudo em Configurações e Canais é submenu
Abrir Configurações mostra um **índice** do que existe dentro; nada nasce expandido. O mesmo em
Canais, onde cada canal tem a sua tela com as contas conectadas daquele canal.
*Justificativa:* a versão anterior abria Provedores de IA junto com Agentes na mesma tela. Com
quatro assuntos em Configurações e quatro canais, empilhar tudo numa página só deixa de ser
navegação e vira rolagem.
**Consequência:** o rail tem grupos que abrem e fecham, e só o grupo da tela atual fica aberto.
Clicar num grupo já aberto fecha — nunca pula direto para o conteúdo de um filho.

### D22 — O não-oficial passa a ser UAZAPI; Evolution fica no catálogo
Revisa D14. Ela concluiu Evolution porque o inventário da Fase 0 não achou UAZAPI em repositório
nenhum, e deixou a pergunta explícita: *confirmar com o time comercial se há compromisso contratual
com UAZAPI que eu não enxergo pelo código*. Há. Então UAZAPI é o não-oficial daqui para frente.
*Justificativa:* a decisão é contratual, não técnica — e D14 já previa isto ao dizer que era
"reversível a custo baixo, porque a interface `ChannelAdapter` não conhece provedor". Foi
exatamente isso: uma classe em `adapters/whatsapp-uazapi.ts` e uma linha no catálogo.
**Evolution não sai.** É o que roda hoje no legado e é para onde os chips existentes apontam;
removê-la do catálogo quebraria a chave estrangeira dessas contas no dia do backfill. Os dois
convivem, UAZAPI aparece primeiro, e a troca de chip é operacional — conta a conta.
**Sobre a API:** confirmado na documentação que o envio é `POST {base}/send/text` com corpo
`{number, text}` e autenticação por header `token` (o da instância, nunca o `adminToken` — enviar
não precisa de poder administrativo). O nome do campo que carrega o id da mensagem varia entre
versões, então o adapter lê de uma lista de grafias em vez de um caminho fixo. Isso está comentado
no arquivo, separando o que é confirmado do que é defensivo.

### D23 — Nas APIs não oficiais, resposta só encerra enrollment se vier citando
`registrar_evento_provedor` liga o retorno à mensagem por `provider_message_id`. Nas APIs oficiais
isso funciona: a Meta e a Gupshup mandam o `context` da mensagem respondida. Nas não oficiais, a
resposta do contato normalmente **não cita nada** — o payload traz o id da mensagem *dele*, que não
existe em `messages`.
*Decisão:* o adapter da UAZAPI só emite `respondido` quando há citação. Sem citação, não emite —
gravar o id dele seria inventar um vínculo que nunca casa.
**Consequência, que é um buraco aberto:** a invariante 4 (resposta encerra o enrollment inteiro)
**não vale** para resposta sem citação no canal não-oficial. O contato responde, o motor não fica
sabendo, e a cadência continua. Vale hoje para Evolution também — o adapter atual emite o id da
mensagem do contato, que igualmente não casa; a diferença é que ele registra um evento inútil em vez
de nenhum.
**Fechada por D24:** a decisão foi uma URL de webhook por `sender_account`.

### D24 — Um endpoint de webhook por chip
Cada `sender_account` nasce com um `webhook_token` (uuid aleatório) e a sua URL própria:
`/canal-webhook/<token>`. Era por provedor; passou a ser por conta.
*Justificativa:* fecha D23. Quem recebe o evento precisa saber de qual chip ele veio, porque é daí
que sai o tenant — e sem tenant, casar uma resposta pelo número escolheria a mensagem de outro
cliente. A alternativa (o provedor mandar a instância no payload) depende de cada provedor mandar,
e de mandar certo; a URL é nossa e vale para todos.
**Como a resposta encerra a cadência agora:** `registrar_resposta_por_numero(chip, número)` acha a
última mensagem que aquele tenant mandou para aquela identidade e grava `respondido` nela. O
encerramento continua saindo do gatilho de `message_events` — a invariante 4 não ganhou um segundo
caminho, ganhou uma segunda entrada para o mesmo caminho.
**Duas escolhas dentro disso, ambas contraintuitivas:**
- *Não filtra por chip.* A pessoa responde para quem falou com ela, e o pool pode ter trocado de
  chip entre um toque e outro.
- *Não filtra por status da mensagem.* `pendente` entra porque o webhook pode ganhar do
  despachante: o provedor entrega, a pessoa responde e o retorno chega antes de
  `registrar_resultado_envio` gravar `enviado`. Filtrar perderia exatamente a resposta mais rápida.
**O token é a credencial.** Quem tem a URL pode postar evento naquele chip. São 128 bits aleatórios,
um por conta, e token desconhecido responde 404 sem dizer mais nada.
**Evolution também foi corrigida:** ela emitia o id da mensagem do contato, que nunca casava com
`messages`. Agora casa pelo número, como a UAZAPI.

### D25 — A plataforma cria a instância; o segredo nasce no Vault
`provider_servers` guarda URL e token de administração do provedor (o token no Vault, sem coluna de
texto). A partir dele, `provisionar-instancia` cria a instância, guarda o token dela no Vault e
cria o `sender_account` — tudo sem ninguém abrir o painel do provedor.
*Justificativa:* chip novo era trabalho manual em dois sistemas, e o token acabava colado em algum
lugar no caminho. Aqui ele vai do provedor para o Vault sem passar por tela.
**A ordem não é arbitrária:** sorteia o token do webhook → cria a instância no provedor já
apontando para esse endpoint → só então grava conta e credencial, numa transação. Criar primeiro no
banco deixaria conta apontando para instância que não existe se o provedor recusasse; criar a
instância sem webhook e apontar depois deixaria uma janela em que a resposta do contato se perde.
No pior caso sobra uma instância órfã no painel do provedor — visível e descartável, em vez de
silenciosa no nosso banco.
**Não é tabela por canal** (anti-regra): é por provedor. Serve a uma Evolution self-hosted no dia
que precisar. Provedor que não hospeda instância — Gupshup, Meta — não aparece na tela: quem cria
número ali é a operadora.
**Consequência de higiene:** `get_decrypted_meta_token`, que o worker chamava e não existia em
migration nenhuma, virou `segredo_do_remetente`. O despachante quebraria na primeira mensagem real.

### D26 — Provedor se configura no painel do produto, não no do Supabase
`salvar_servidor_provedor` e `salvar_credencial_remetente` gravam no Vault a partir da tela.
*Justificativa:* `provider_servers.admin_secret_id` existia e não havia como preenchê-lo de dentro
da aplicação — escrever no Vault é SECURITY DEFINER, e nada com SECURITY DEFINER estava exposto ao
usuário logado (D19). Na prática isso significava abrir o dashboard do Supabase e colar o token, o
que é o dono do produto tendo acesso de operador do banco. Um cliente do SaaS nunca vai ter isso.
**São a exceção ao D19, e por isso checam permissão em código.** SECURITY DEFINER passa por cima da
RLS; então a pergunta que a política faria (`pode_administrar`) é feita dentro da função. Há teste
para operador barrado e para quem administra passando — é o tipo de checagem que some numa
refatoração sem ninguém notar.
**Token em branco na edição não apaga o guardado.** O campo volta vazio porque segredo não é
legível; tratar vazio como "apagar" derrubaria um servidor que está funcionando.
**O catálogo decide o que é credencial.** Campo que não existe no provedor é recusado em vez de ir
para o Vault como se fosse dele.

### D27 — Oficial e não oficial são telas separadas
`Canais ▸ WhatsApp` virou índice de duas telas: **API Oficial** (Gupshup, Meta) e **API não
oficial** (UAZAPI, Evolution). O servidor de instância mora dentro da segunda, que é o único mundo
em que ele existe.
*Justificativa:* não é organização visual. Oficial e não oficial mudam base contratual, risco de
banimento (D11) e qual pool pode usar (D4). Configurar chip de automação e número homologado na
mesma lista é o que faz alguém apontar uma campanha institucional para um chip frio sem perceber.
**A divisão é derivada, não fixa:** sai de `channel_provider_catalog.oficial`. Canal que só tem um
dos dois — SMS, e-mail, Instagram hoje — continua com uma tela só, sem submenu vazio.

### D28 — Quem separa segredo de config é o catálogo, não a tela
`salvar_credencial_ia` recebe todos os campos preenchidos num objeto só e decide, lendo
`ai_provider_catalog`, o que vai para o Vault e o que vai para `config`.
*Justificativa:* a tela de Provedores de IA era o buraco que o D26 deixou — desenhava os campos que
o catálogo declara e não tinha para onde mandá-los. Ligar um agente exigia o painel do Supabase,
exatamente o que o D26 proíbe.
**A alternativa era a UI mandar dois objetos, `segredos` e `config`.** Foi recusada: obriga a tela a
saber que `api_key` é segredo e `base_url` não, e é justamente por não conhecer provedor nenhum que
ela não quebra quando um provedor novo entra no catálogo. Pior que quebrar: a UI errando a separação
grava chave em `config`, e quem recusa é o gatilho `ai_credentials_sem_segredo` — erro de banco na
cara do usuário, com a chave já tendo passado por onde não devia.
**Chave em branco na edição preserva a guardada,** pela mesma razão do D26: segredo não é legível,
então o campo sempre volta vazio.
**`segredo_da_credencial_ia` não é API.** Devolve a chave em texto claro; só o `service_role` chama.
Nasce sem EXECUTE para ninguém, como manda o D19 — conceder é decisão. Há teste conferindo que
`authenticated` *não* alcança essa, e alcança a de escrita.

### D29 — A chave do motor não mora no comando do job
`privado.agendar_motor()` agenda `SELECT privado.acordar_motor('<url>', <limite>)`. A service key
não aparece: quem a lê é `privado.chave_do_motor()`, do Vault, no instante da batida.
*Justificativa:* a receita corrente para cron + edge function é colar a service key dentro do
comando do job. O comando vive em `cron.job`, que é uma tabela como outra qualquer — vai para
backup, réplica e `pg_dump`, e aparece inteiro para quem tiver SELECT nela. É a anti-regra "nunca
colocar secret fora do Vault", só que escondida atrás de um tutorial.
**O agendamento é operação da plataforma, não do cliente.** As cinco funções nascem em `privado`,
sem EXECUTE para `anon` nem `authenticated`, e só o `service_role` recebe. Não são API e nunca vão
ser: nenhum tenant agenda o motor de ninguém.
**`pg_cron` e `pg_net` entram pela própria migration,** guardadas por `pg_available_extensions` —
o Postgres do teste não as tem, e referência direta faria a suíte inteira parar de aplicar.
**A reversão não derruba as extensões.** São do projeto, não deste schema: outra coisa pode ter
passado a depender delas, e um `CREATE EXTENSION` custa menos que descobrir o que quebrou.
**`ultimas_passadas` existe porque shadow mode não tem sintoma.** Ninguém recebe mensagem, então um
401 no worker pareceria exatamente igual a "não havia vencidos".

### D30 — E-mail sai por provedor HTTP, não por SMTP
O adapter de e-mail é `resend`. `smtp` continua no catálogo com `tem_adapter = false`.
*Justificativa:* `adapters/tipos.ts` diz, na primeira linha, que ali não entra API de runtime — só
`fetch`. É o que faz o mesmo arquivo rodar no Deno da edge function e no Node do teste, sem mock.
SMTP precisa de socket. Ligar SMTP significaria abrir essa exceção para os quatro canais de uma vez,
e um provedor HTTP entrega o mesmo e-mail sem cobrar esse preço.
**`smtp` não sai do catálogo,** pelo mesmo motivo que a Evolution ficou quando a UAZAPI entrou
(D22): sumir com a opção esconde a decisão. Fica listado, declarado sem adapter, com a descrição
dizendo por quê — o motor recusa antes de prometer, em vez de falhar na hora do disparo.
**O assunto vem do próprio passo, não de uma coluna nova.** `flow_steps.template` é um texto só
porque os outros três canais não têm assunto; abrir coluna no motor para a necessidade de um canal
contraria "canal novo = classe nova, zero mudança no motor". O passo pode começar com
`Assunto: ...`, e quando não começa vale `assunto_padrao` — **campo obrigatório do remetente**, de
modo que "passo de e-mail sem assunto" deixa de ser um estado possível.
**A alternativa óbvia — "a primeira linha é o assunto" — foi recusada:** transforma todo parágrafo
curto de abertura em assunto sem que ninguém tenha pedido, e um template já escrito viraria um
e-mail errado sem aviso.
**4xx do provedor é culpa do remetente, não do destino.** `culpa = 'destino'` marca
`contact_identities.valida = false` e escreve `identidade_invalida` no CRM; um domínio não
verificado queimaria o e-mail do contato por um erro que é da conta. Quem diz que um endereço morreu
é o `email.bounced` do webhook.
**`responder_para` é o que faz a invariante 4 valer no canal.** A resposta só vira `email.received`
se cair num domínio de inbound; sem isso a pessoa responde para uma caixa que o motor não lê e a
cadência continua andando — o mesmo furo que o D23 fechou no WhatsApp não oficial. E o casamento é
pelo endereço, nunca pelo `email_id` do e-mail recebido, que é da mensagem dela e não existe em
`messages`.
**`Idempotency-Key` leva a invariante 1 para o outro lado da rede.** A chave única
`(enrollment_id, step_id)` garante uma mensagem no banco; o lease pode expirar e a mesma mensagem
ser reivindicada de novo, e aí quem impede o segundo envio é o provedor.
**Junto veio a checagem de campo obrigatório em `salvar_credencial_remetente`,** que a de IA já
tinha e esta não. Sem ela, `assunto_padrao` obrigatório seria enfeite do catálogo validado só pela
tela — e quem valida não pode ser a tela (D28).

### D31 — O pool pergunta ao catálogo antes de escolher remetente
`remetentes_disponiveis` passa a exigir `tem_adapter` e `ativo` do provedor.
*Justificativa:* `tem_adapter` existia desde o D17 e **nenhum SQL o lia**. O README, o comentário da
tabela e a própria migration do D30 afirmavam "provedor sem adapter não vira opção de envio: o motor
recusa antes de prometer" — e não era verdade. Reproduzido antes de corrigir: conta de e-mail em
`smtp` devolvia `mensagem_criada`.
**O estrago não era o erro, era o passo queimado.** O roteador escolhia a conta, `processar_vencidos`
criava a mensagem e avançava `passo_atual` e `next_run_at`, e só o despachante estourava — virando
`culpa = 'remetente'`, falha registrada e health score derrubado. A pessoa nunca recebia o toque, a
cadência andava como se tivesse recebido, e o console mostrava uma conta boa adoecendo por um
provedor que nunca soube enviar.
**Adiar é recuperável; queimar não.** Sem candidato o roteador já fazia a coisa certa —
`adiado_sem_remetente` — e no dia em que o adapter existir os enrollments parados andam sozinhos.
**Cadastrar a conta continua permitido.** Os chips do legado apontam para provedores que podem não
ter adapter no dia do backfill; foi por isso que o D22 manteve a Evolution no catálogo. Quem filtra
é o pool, não a chave estrangeira.
**`ativo` entra junto pela mesma razão:** o gatilho só olha o INSERT, então nada impedia uma conta já
criada de continuar sendo escolhida depois de o provedor ser desligado no catálogo.
**`proximo_horario_de_pool` não muda.** Ela só responde "quando vale a pena reperguntar", e
reperguntar cedo demais não machuca ninguém.
**O demo era o cenário defeituoso.** `demo/preview.sql` tinha justamente uma conta de e-mail em
`smtp` — mais uma vez foi o cenário completo, e não o teste unitário, que expôs a diferença entre o
que estava escrito e o que o motor fazia (como no D15).
**A mesma varredura achou o formato de falha repetido nos meta-testes.** `tests/tenants.sql`
conferia RLS contra uma **lista de tabelas escrita à mão**, e a lista já tinha ficado para trás:
`provider_servers` entrou com o D24 e nunca foi adicionada — tinha RLS por sorte, não por
verificação. Pior: a FK composta `(tenant_id, id)`, que o D18 chama de camada 2 e é a única que
vale contra o worker (service key, RLS não alcança), era a garantia mais citada do projeto e não
tinha asserção nenhuma. Os três meta-testes agora são derivados do schema: tabela nova nasce
obrigada a ter `tenant_id`, RLS e FK composta, e isentá-la exige entrar numa lista curta de exceções
e dizer por quê. Cada um foi verificado contra uma violação real antes de entrar — asserção que
nunca falha é do mesmo tamanho de coluna que ninguém lê.

### D32 — A ingestão existe, e o dedup mora no banco
`ingerir_contato(tenant, origem, identidades, nome, origem_ref, metadados)` é a entrada de contato.
`ContactSource` no TypeScript lê a fonte e normaliza; o SQL dedup e grava.
*Justificativa:* o `CLAUDE.md` diz "entrada implementa `ContactSource`" e o D1 nomeia
`PlanilhaSource` e `PipefySource` — **nada disso existia, nem a interface**. Em SQL havia só
`inscrever()`, que inscreve um contato que já existe. Não havia como pôr contato no sistema a não
ser escrevendo INSERT à mão, e portanto o motor completo nunca pôde rodar sobre dado real, nem em
shadow mode. Terceiro achado da mesma varredura do D31: o documento afirmava, o código não fazia.
**O dedup fica no banco porque precisa ser atômico** com o índice único
`(tenant_id, canal, valor_norm)`. Duas linhas para a mesma pessoa é o que o D2 proíbe, e separar o
SELECT do INSERT entre processos reabre a corrida — mesmo argumento que manteve o roteador em SQL.
**A normalização NÃO fica no banco,** e essa é a parte contraintuitiva. Ela já mora em
`adapters/telefone.ts` e `adapters/email.ts`, e é de lá que o webhook casa resposta pelo número
(D23). Um segundo normalizador em SQL produziria duas normalizações divergentes — que é, literalmente,
como a supressão fica furada. Então o chamador manda `valor` e `valor_norm`, e `privado.normalizada`
**confere em vez de normalizar**: é trava contra chamador desatento, não um segundo normalizador.
**Fundir dois contatos existentes é recusado, não decidido.** Quando as identidades de uma linha já
pertencem a pessoas diferentes, a importação para com `restrict_violation`. Fundir é destrutivo e não
tem volta; escolher um dos dois em silêncio seria pior do que falhar.
**Identidade suprimida é gravada e contada,** não escondida. O gate é o roteador (invariante 2), e o
cadastro completo é o que faz o writeback no CRM fazer sentido — o que ela ganha na ingestão é
visibilidade: quem importa 500 linhas merece saber que 12 nunca serão tocadas.
**Nome só preenche, metadados só mesclam.** Reimportar uma planilha sem a coluna de nome não pode
apagar o nome que já estava lá, e a segunda fonte acrescenta em vez de substituir.
**O regex não tem barra invertida, de propósito.** A primeira aplicação no projeto passou por um
transporte que duplicou o `\` do ponto escapado, e no banco o padrão virou "exija uma barra
invertida literal no e-mail" — o que recusaria **todo** endereço. O suite não podia pegar: ele roda
o arquivo, onde estava certo. Quem pegou foi o digesto estrutural contra o banco de teste, e a
correção foi escrever o ponto como classe de caractere. É o argumento do digesto ganhando sozinho o
seu custo.

### D33 — A planilha decide o canal pelo cabeçalho, e fixo não vira WhatsApp
`PlanilhaSource` lê o CSV que a operação exporta e devolve contatos normalizados sem escrever nada.
Coluna cujo cabeçalho declara o canal (`WhatsApp`, `SMS`) produz identidade só naquele canal. Coluna
genérica (`Telefone`, `Celular`, `Fone 2`) produz **whatsapp e sms** quando o número é celular, e
**nenhuma identidade** quando é fixo.
*Justificativa:* planilha de operação não tem esquema, e exigir que a pessoa renomeie a coluna antes
de importar é o atrito que faz a importação voltar a ser INSERT à mão. Mas "telefone" não diz canal,
e as duas saídas fáceis são erradas: emitir só `sms` perde o WhatsApp, que é o canal principal;
emitir os dois para qualquer número promete WhatsApp num fixo — e aí o roteador escolhe um destino
que não existe, gasta o passo e derruba a saúde do remetente com uma falha que não era dele. É o
mesmo erro do D31, uma camada acima: o pool não pode prometer o que o despachante não faz, e a
ingestão não pode prometer o que o número não tem. Para o DDI 55 a distinção é confiável (nove
dígitos começando em 9 depois do DDD); fora dele não se adivinha, e o número entra — quem recusa é
o provedor, que é melhor do que descartar em silêncio um internacional bom.
**O que não vira identidade continua visível.** Um telefone com dígito a menos numa linha que tem
e-mail bom não recusa a linha, mas sai em `ignorados` com coluna, valor e motivo. Silêncio aqui é
caro: o contato entraria sem que ninguém soubesse que o telefone se perdeu. Coluna que o motor não
conhece (`Plano atual`, `Corretor`) vira metadado em vez de sumir.
**O número da linha é o que o Excel mostra.** `lerCsv` deixa a linha em branco na lista de
propósito: descartá-la faria o índice andar, e é por esse número que a pessoa acha na planilha dela
a linha que foi recusada.
**Colher é puro, e é isso que torna a prévia possível.** A fonte não escreve, não sabe o que é
tenant e não decide dedup — então a tela consegue mostrar "entram 480, 12 são reimportação, 3 não
têm identidade" antes de qualquer gravação. Mesma ideia do shadow mode: o caminho inteiro roda sem
efeito.
**`adapters/instagram.ts` nasce antes do adapter de Instagram.** O handle precisa ser normalizado
hoje, e `instagram_oficial` ainda está com `tem_adapter = false` (D30). O que não pode acontecer é a
normalização nascer dentro da tela de importação e depois divergir da que o adapter usar — pela
mesma regra do D32, endereço normalizado é chave de dedup e de supressão.
**O teste de ponta a ponta existe porque os outros dois usam cópias.** `tests/fontes.test.ts` repete
as expressões da trava; `tests/ingestao.sql` usa identidades escritas à mão. Nenhum roda a saída
real da `PlanilhaSource` contra a `ingerir_contato` real — e é o par que roda em produção, não cada
metade. Renomear `valor_norm` no JSON deixa os dois verdes e mata a importação inteira, porque a
trava recusa a chamada toda, não a linha.

### D34 — Prévia antes de gravar, e o motor passa a ter tipo
A tela de importação lê o arquivo com `PlanilhaSource`, mostra o que a fonte entendeu, chama
`prever_ingestao` para saber o que aconteceria, e só então grava — uma chamada de
`ingerir_contato` por linha.
*Justificativa:* sem prévia só há duas opções e as duas são ruins: importar e ver o que aconteceu,
ou abrir transação e desfazer, que o PostgREST não permite. É a mesma ideia do shadow mode — o
caminho inteiro roda sem efeito.
**A prévia é linha a linha porque a trava recusa a chamada, não a linha.** Uma identidade malformada
no meio de 500 mata a importação inteira; quem importa merece saber disso antes, e escolher.
**O canal não é convertido com cast.** Vem como texto do cliente, e um cast direto aborta a prévia
inteira num valor inválido — exatamente o que ela existe para evitar. Casa contra os rótulos do
enum e recusa só a linha. Verificado: com o cast, a chamada morre em `invalid input value for enum`.
**A gravação é uma chamada por linha, de propósito.** Um laço no servidor seria uma viagem só, mas
poria as 500 linhas na mesma transação: uma recusa no meio desfaz as 499 que já passaram. Assim cada
linha é a sua própria transação, o progresso é real, e a que falha não leva as outras. O custo é a
latência, e é o custo certo — importação é operação de uma vez por dia, não caminho quente.
**A tela conferência número um é "o que virou o quê".** É a pergunta que ninguém pensa em fazer: uma
planilha com a coluna "Fone Comercial" importa 500 contatos sem telefone nenhum e sem erro nenhum.
**`app/` importa `adapters/` por alias, em vez de copiar.** Copiar o leitor de CSV e os
normalizadores para dentro do app seria a segunda normalização que o D32 proíbe — e a divergência
entre as duas cópias não apareceria em teste, apareceria em supressão furada.
**E foi aí que apareceu o achado:** ao puxar `adapters/` para dentro do `tsc` do app, **oito erros de
tipo reais** surgiram de uma vez. `adapters/` e `motor/` **nunca tinham sido checados por tipo** —
`node --experimental-strip-types` **apaga** os tipos, não os confere, e o `tsconfig.json` do app
olhava só `app/src`. As anotações do motor inteiro valiam de comentário. Nenhum dos oito quebrava
hoje; todos eram do tipo que quebra num payload diferente do do teste (acesso a índice que podia ser
`undefined`, um `flatMap` cujos ramos o compilador não unificava). Agora há `tsconfig.json` na raiz,
com `noUncheckedIndexedAccess`, e `tests/run.sh` roda o `tsc` antes dos testes. Mesmo formato do D31
e do D32: a garantia estava escrita, a verificação não existia.

### D35 — Prévia da inscrição, porque o erro aqui é silencioso
`prever_inscricao(tenant, campanha, flow_version, contatos[])` diz, por contato, se ele entra, se
já está inscrito, se está suprimido ou se não há como alcançá-lo — sem gravar nada. A tela de
contatos seleciona quem, escolhe onde, confere, e só então inscreve.
*Justificativa:* das três formas de a inscrição dar errado, a pior **não dá erro nenhum**.
Inscrever um contato sem identidade no canal dos passos é aceito; o roteador faz
`passo_pulado_sem_identidade` e empurra o enrollment adiante, passo a passo, até encerrar em
`fim_dos_passos`. O relatório mostra **"campanha concluída"** para quem nunca recebeu nada.
Inscrever 500 e descobrir isso depois custa o tempo e, pior, a confiança no número.
As outras duas dão erro, e erro que mata a chamada inteira: reinscrever quem já está inscrito bate
no índice parcial `enrollments_contato_campanha_ativo_uk`; e contato suprimido faz `inscrever`
devolver **NULL em silêncio** — quem chamou recebe um nulo sem motivo e não sabe se foi supressão,
campanha inexistente ou bug.
**Alcançável são três coisas ao mesmo tempo:** identidade `valida`, num canal que o flow usa **e**
que a campanha habilita, e que não esteja suprimida. Qualquer uma sozinha engana.
**O bug que o teste pegou:** `array_agg(DISTINCT ci.canal)` numa junção externa sem par produz
`{NULL}`, e `array_length` devolve **1** — "não tem canal nenhum" passava por "tem um canal", e a
prévia dizia `inscrever` exatamente para quem o motor encerraria sem mandar nada. O `FILTER (WHERE
ci.canal IS NOT NULL)` é o conserto. A prévia estava reproduzindo o silêncio que ela existe para
quebrar.
**Campanha e flow são escolhidos separadamente porque o schema não liga os dois.** `campaigns` não
tem `flow_version_id`; a dupla só existe dentro de `enrollments`. A tela mostra os canais de cada
lado e avisa, antes de qualquer chamada, quando eles não se cruzam — mas isso é contorno de uma
lacuna de modelagem, não solução. Registrar em vez de inventar coluna: a decisão de como ligar
campanha a flow (uma? várias? versionada junto?) é de produto.

### D36 — O shadow mode precisa de tela, senão parece defeito
`resumo_da_campanha` e `eventos_da_campanha` alimentam `app/src/telas/Campanha.tsx`: quantos em
cadência, quantos encerrados e por quê, quantas mensagens e em que status, respostas, cliques, e
quando é a próxima batida.
*Justificativa:* depois de inscrever, o app não mostrava nada. O console (`ui/console.html`) mostra
o **demo**, não o cliente. E o momento em que isso mais dói é exatamente o primeiro: shadow mode
roda o caminho completo e **não envia nada** — sem uma tela dizendo "12 mensagens, todas em shadow
mode", o modo que de-risca o projeto inteiro é indistinguível de estar quebrado.
**Contar no banco, não no cliente.** Milhares de enrollments não passam pelo PostgREST linha a
linha. E `min(next_run_at)` responde a única pergunta que a pessoa realmente faz na primeira semana:
"quando é a próxima?".
**Resposta e clique são KPIs separados, e vêm do evento.** `message_events` é append-only e o status
é derivado; contar pelo evento é o que faz o número bater com a invariante 4 e com o D7 — clique
aparece e **não** encerra.
**O que o teste me corrigiu:** eu tinha assumido que em shadow mode não há remetente, e ia rotular a
coluna como `(shadow mode)`. Falso: `processar_vencidos` **escolhe e reserva** remetente igual, só
não envia. A coluna teria mentido. Quem diz que nada saiu de casa é o `status` da mensagem, e ele
entrou na linha do tempo por causa disso.
**E um teto que era enfeite.** O `least(p_limite, 500)` da linha do tempo passava no teste com e sem
o `least`, porque o cenário tinha três eventos — mesmo formato do `tem_adapter` do D31. Agora o
teste insere 600 eventos e cobra os 500.

### D37 — Os pendentes passam a rebalancear de verdade
`reivindicar_pendentes` vira plpgsql: antes de entregar uma mensagem ao despachante, confere se o
remetente gravado ainda despacha. Se não, troca por outro do mesmo pool; se não houver nenhum,
devolve a mensagem à fila em vez de entregá-la a uma conta morta.
*Justificativa:* a invariante 3 do `CLAUDE.md` promete "conta com erro sai do pool sozinha (circuit
breaker) e **os pendentes rebalanceiam**" — e o comentário do `registrar_falha_remetente` dizia até
por quê: *"os pendentes rebalanceiam porque remetentes_disponiveis deixa de retorná-la"*. **O
raciocínio estava escrito e estava errado.** `remetentes_disponiveis` decide para quem vão as
mensagens **futuras**; quem a consulta é o roteador, ao criar a mensagem. Uma mensagem que já existe
carrega o remetente na própria linha, e `reivindicar_pendentes` nunca reperguntava ao pool.
Reproduzido antes de corrigir, com duas contas boas no mesmo pool: com o circuito de A aberto,
`remetentes_disponiveis` devolvia B (certo) e `reivindicar_pendentes` devolvia a mensagem com A
(errado). O estrago é um laço: o despachante tenta por uma conta morta, falha, a falha volta como
`culpa = 'remetente'` e afunda A mais um pouco, a mensagem segue `pendente`, e na próxima expiração
do lease tudo se repete — com B parado ao lado.
**A reserva do remetente antigo não é devolvida.** Não dá para saber se ele chegou a entregar antes
de adoecer, e devolver o crédito é o único jeito de furar a invariante 3: contar a mais aperta o
envio, contar a menos ultrapassa a quota.
**Quota não entra na checagem do remetente atual.** A reserva daquela mensagem já foi paga quando o
roteador a criou; recobrar seria negar o mesmo envio duas vezes.
**Circuito vencido passa a fechar na borda do lote.** Antes só fechava dentro de `reservar_envio`,
que só roda para quem já foi escolhido — e o pool não escolhe conta de circuito aberto. A conta
ficava presa até alguém tentar usá-la, e ninguém tentava.
**O meta-teste pegou um erro meu no arquivo de reversão.** O `down` refazia a função com
`CREATE OR REPLACE` sem `SET search_path`, que é exatamente o que o D19 aplica por ALTER em massa e
o que `CREATE OR REPLACE` descarta — terceira vez que essa armadilha aparece no projeto, e a
primeira em que foi um teste, e não uma leitura atenta, que a pegou.

### D38 — O evento do provedor passa a dizer de qual chip veio
`registrar_evento_provedor` recebe o chip (`p_sender_id`), tira o tenant dele e filtra a busca.
A assinatura antiga foi derrubada, não mantida ao lado.
*Justificativa:* a função procurava assim, em todos os clientes:
`SELECT id FROM messages WHERE provider_message_id = ? ORDER BY criado_em DESC LIMIT 1`.
`provider_message_id` é do provedor, não nosso, e nada garante que dois clientes não recebam o
mesmo. Com o id colidido, o evento cai na mensagem mais nova — e se o evento é `respondido`,
**encerra a cadência do cliente errado**; se é `rejeitado`, invalida a identidade de outro cliente e
escreve `identidade_invalida` no CRM dele. Reproduzido antes de corrigir: dois clientes com o mesmo
`provider_message_id`, um webhook de resposta, e o enrollment do Cliente B encerrado por um evento
que podia ter vindo do chip do Cliente A.
É o dano do D24 na outra via de casamento, e é literalmente a anti-regra: *"Nunca deixar tenant
implícito em assinatura de função. É como bug entre clientes acontece."* A irmã dela,
`registrar_resposta_por_numero`, já fazia certo desde o D24 — e o comentário do `motor/webhooks.ts`
explicava a razão no ramo de baixo enquanto o ramo de cima cometia o erro: *"Sem chip não há tenant,
e sem tenant casar pelo número escolheria a mensagem de outro cliente."*
**`senderId` deixa de ser opcional em `receberWebhook`.** Como opcional, esquecê-lo casava errado;
como obrigatório, quem cobra é o compilador. E há guarda em tempo de execução junto, porque a edge
function roda JavaScript e um chamador sem tipos passaria `{}`.
**Três armadilhas de teste apareceram escrevendo este teste**, e valem mais que a correção:
um `EXCEPTION` envolvendo o bloco inteiro **desfaz as asserções anteriores** — quatro `confere`
viraram um, em silêncio; reaproveitar o cenário de outro teste fez três asserções falharem por
motivo que não era o delas; e chamar a função e conferir o efeito dela **na mesma expressão SQL**
não funciona, porque o `EXISTS` ao lado lê o snapshot do início da instrução e não vê a linha que a
função acabou de gravar.

### D39 — A supressão vale também depois da mensagem criada
`reivindicar_pendentes` repergunta a supressão antes de entregar cada mensagem ao despachante. Quem
entrou na lista depois de a mensagem existir tem a mensagem marcada `cancelado` e não sai.
*Justificativa:* a invariante 2 diz "contato em `suppression` nunca recebe nada, **por nenhum
caminho de código**". O gatilho `messages_respeita_supressao` guarda o INSERT em `messages`, ou
seja, o momento em que o roteador cria. O despacho não tinha portão nenhum, e entre criar e
despachar existe uma janela: a mensagem nasce `pendente` e espera. Se a pessoa pede para sair nesse
meio — por telefone, por outro canal, por importação de lista de opt-out — a mensagem saía assim
mesmo. E **desde o D37 a janela é ilimitada**, porque sem remetente disponível a mensagem fica
pendente indefinidamente.
Reproduzido antes de corrigir: mensagem pendente, `suppression` inserida, `esta_suprimido`
devolvendo true, e `reivindicar_pendentes` entregando a mensagem ao despachante mesmo assim.
Num produto de prospecção fria no Brasil é o defeito mais caro da varredura: o opt-out está
registrado e a mensagem vai embora.
**`cancelado` é estado novo, não sinônimo de `falha`.** Mesmo argumento do D13, que criou
`cancelado_operacional`: forçar isto em `falha` faria o painel contar opt-out honrado como falha do
motor, e faria a conta que ia enviar levar a culpa no health score. O valor entra por
`ALTER TYPE ... ADD VALUE`, aditivo, e o `down` não o remove — `DROP VALUE` não existe no
PostgreSQL, e recriar o tipo obrigaria a reescrever a coluna de toda mensagem. Valor de enum a mais
é inerte.
**O portão vem antes de tudo na função,** antes de quota, de pool e de rebalanceamento: é o que
"acima de qualquer regra do cliente" quer dizer.
**O enrollment continua sendo encerrado pelo agendador,** na batida seguinte, que já faz isso e tem
teste. O assunto aqui é só não deixar a mensagem sair.

### D40 — O despachante concorda com o agendador
`reivindicar_pendentes` passa a olhar o estado do enrollment e da campanha. Parada definitiva
cancela a mensagem; parada temporária a segura na fila; `fim_dos_passos` despacha normalmente.
*Justificativa:* é a pergunta que o D39 deveria ter provocado na hora. Se a supressão precisava de
portão no despacho porque a janela `pendente` é ilimitada, **o que mais assume que essa janela é
curta?** Três coisas, todas reproduzidas:

| situação | enrollment | despachava |
|---|---|---|
| pessoa respondeu | `encerrado` / `resposta` | sim |
| operador pausou | `pausado` | sim |
| campanha desligada | `ativo`, campanha `ativa = false` | sim |

A primeira é a **invariante 4 furada pela borda**: "resposta em qualquer canal encerra o enrollment
inteiro, não só o passo" — e a mensagem já enfileirada saía mesmo assim, ou seja, quem acabou de
responder levava mais um toque. As outras duas são o despachante discordando do agendador sobre o
mesmo fato: `processar_vencidos` já pula campanha inativa e só olha enrollment ativo.
**A regra óbvia está errada, e o experimento mostrou por quê.** "Só despacha enrollment ativo"
mataria a última mensagem de **todas** as cadências: no último passo o agendador cria a mensagem e
encerra o enrollment com `fim_dos_passos` na mesma passada. Foi um cenário de um passo só que
expôs isso — e, quando sabotei a função com a regra ingênua, quem reprovou foi um teste que já
existia (`tests/rebalanceamento.sql`, seis asserções), não o novo.
**Parada temporária segura, não cancela.** Pausa e campanha desligada voltam atrás; cancelar
perderia o passo para sempre, porque a chave única `(enrollment_id, step_id)` impede recriá-lo.
Mesma lógica do D37: adiar é recuperável, queimar não é.
**`falha_permanente` entra em "cancelar"** junto com os outros. Nada no motor o produz hoje — só o
mapa do backfill — e enrollment que terminou em falha permanente não ganha nada com mais um toque.

### D41 — A supressão ganha porta de entrada
Tela `app/src/telas/Supressao.tsx`: lista quem está suprimido, adiciona um endereço, importa uma
lista de opt-out. Suprimir o contato inteiro fica na linha da pessoa, na tela de contatos.
*Justificativa:* a invariante 2 se apoia inteira nesta tabela, e o D39 e o D40 a tornaram
autoritativa até no despacho — mas **nada no motor, no app ou no webhook escrevia nela**. Só SQL à
mão. É o mesmo buraco que o D32 achou na ingestão: a garantia existia, a porta de entrada não.
**Sem função nova em `public`.** `authenticated` já tem INSERT e a política de RLS já carrega a
regra; criar uma função só para repetir o que a política diz aumentaria a superfície do PostgREST
sem ganhar garantia. O teste passou a exercitar esse caminho **no papel de quem usa o produto**:
operador insere, leitor é recusado com 42501, e operador da A não suprime no cliente B. As duas
negativas foram conferidas contra a versão que passaria.
**O canal é deduzido do que foi digitado, pelos normalizadores dos adapters.** Telefone entra em
whatsapp **e** sms — quem pediu para parar não pediu só num canal. É a leitura da coluna genérica
do D33 com a consequência invertida, e por isso segura: suprimir a mais nunca machuca ninguém.
**A importação de lista reusa `PlanilhaSource`.** Normalizar em outro lugar é exatamente como a
supressão fica furada (D32), e o primeiro dia de qualquer migração é justamente a lista de opt-out
que já existia antes do motor.
**Duplicata não é erro.** `23505` do índice único vira "já estava lá" — do ponto de vista de quem
pediu para sair, o resultado é o mesmo.
**Não há remover, e a tela diz por quê.** A tabela é imutável por gatilho; tirar alguém dali seria
voltar a falar com quem pediu para parar. Suprimir um contato pede confirmação pela mesma razão.

**O que isto NÃO resolve, e continua aberto:** quem responde "PARE" numa cadência tem o enrollment
encerrado por resposta (invariante 4), **mas não entra na supressão** — então a campanha seguinte
volta a falar com ele. Detectar opt-out em texto livre é decisão de produto (e há agentes de IA no
schema para isso); está anotado junto com a pergunta de bounce e denúncia.

### D42 — Ler o que o motor compôs, e o rastro que a variável vazia deixa
`mensagens_da_campanha` devolve o texto renderizado de cada mensagem, com canal, destino, passo,
status e remetente — e um booleano `buraco` marcando suspeita de variável sem valor. A tela da
campanha mostra, atrás de um clique.
*Justificativa:* o shadow mode roda o caminho inteiro sem enviar. Mas o texto composto — o que a
pessoa receberia — não aparecia em lugar nenhum do produto: o painel mostrava eventos, não conteúdo.
Sem isso, o modo que de-risca o projeto **não pega a classe de erro mais provável de todas**, que é
o template errado.
**E há uma que ele pega sozinho, se alguém puder ler.** `renderizar` troca chave ausente por string
vazia, e não pela marcação crua. A decisão está certa, e o comentário dela argumenta bem — "mandar
`Oi {{nome}}` para um cliente é pior do que mandar `Oi`". Só que o resultado, para um contato sem
nome, é isto:

    Olá {{nome}}, tudo bem?            ->   Olá , tudo bem?
    {{nome}}, você é de {{cidade}}.    ->   , você é de .

Ninguém escreve "Olá ," à mão. E uma lista fria entra justamente sem nome e sem cidade, então isso
sai em **toda** mensagem da campanha.
**Marcar, não corrigir.** Consertar o texto seria decidir a redação por quem escreveu o template:
"Olá, tudo bem?" pode não ser o que a pessoa queria dizer, e a saída certa talvez seja preencher o
dado, não remendar a frase. A função marca a suspeita por pontuação órfã ou espaço dobrado, a tela
avisa quantas, e quem escreveu decide. Falso positivo aqui custa uma olhada; falso negativo custa
uma campanha inteira dizendo "Olá ,".

### D43 — O cenário do demo tem de acionar o que o demo diz mostrar
`demo/preview.sql` encena, entre criar a mensagem e despachá-la, as três situações que o D37, o D39
e o D40 tratam, e inscreve um contato sem nome para o D42 aparecer. `demo/conferir.py` recusa o
`preview.json` que deixar de conter qualquer uma delas, e roda dentro do `demo/gerar.sh`.
*Justificativa:* os quatro portões estavam no caminho do demo e **nenhum disparava**. Toda batida
passava por `reivindicar_pendentes`, com a supressão, o rebalanceamento e a concordância com o
agendador ali dentro — e o cenário nunca criava um pendente com remetente adoecido, nem uma
supressão com mensagem na fila, nem uma resposta com toque seguinte já criado. O console mostrava
uma cadência tranquila. Isso não quebra teste nenhum: o cenário não fica errado, ele só para de
contar, e a diferença entre "o portão funciona" e "o portão nunca foi tocado" some da tela.
**Relatar o que aconteceu, não o que devia ter acontecido.** A primeira versão deste relato deduzia
a troca de remetente do estado depois do despacho e anunciou troca para quatro mensagens que nunca
saíram do lugar — um demo mentindo na direção mais convincente possível, a de confirmar a correção
recém-feita. O relato agora fotografa o remetente antes de `reivindicar_pendentes` e compara: o
rebalanceamento acontece dentro da função e não deixa rastro na linha de `messages`, então sem a
foto não há como saber, só como supor.
**E o cenário tem de ser o certo para o portão.** A resposta na janela precisa ser de alguém com
passo à frente: `fim_dos_passos` é o único encerramento que o D40 não cancela — de propósito, porque
é o da última mensagem de toda cadência — e encená-la com quem estava no último passo teria
"provado" o contrário do que o portão faz.
**O demo consulta pela porta do produto.** A lista de mensagens do `preview.json` vem de
`mensagens_da_campanha`, não de um `SELECT` próprio — mesma regra que levou a ingestão do demo para
`ingerir_contato` (D32). Um demo que consulta à mão não exercita a tela, e `buraco`, que é o valor
da função, não existiria no console.

### D44 — A chave do motor se confere antes de agendar, sem nunca ser devolvida
`privado.conferir_chave_do_motor(p_url)` diz se o segredo do Vault serve: existe com o nome exato,
não tem espaço nem quebra nas pontas, é JWT ou `sb_secret_`, carrega `role = service_role`, é do
projeto para onde o job vai bater, e não expirou. `LIGAR.md` é o procedimento inteiro, com a
conferência entre guardar e agendar.
*Justificativa:* ligar o motor tem dois passos manuais, e só um deles reclama quando está errado.
Na tela do Supabase a `anon` fica imediatamente acima da `service_role`, com o mesmo formato e quase
o mesmo tamanho. Colar a de cima agenda o job, deixa a batida sair, e faz o worker responder 401 em
toda passada — **e uma passada 401 é indistinguível, em toda a tela do produto, de uma passada sem
vencidos**. É o formato do D31 e do D42 outra vez: o estado errado existe e nada o nomeia. Depois de
agendado, o erro vira silêncio com cara de normalidade, e é procurado no lugar errado.
**Fatos sobre a chave, nunca a chave.** Toda linha da saída descreve o segredo sem carregá-lo, e o
tamanho é reportado como número. Uma função que lê segredo e escreve texto está a uma edição de
vazá-lo, então a asserção existe e foi conferida contra sabotagem: ao forçar a linha do segredo a
ecoar o valor, duas asserções ficam vermelhas.
**Reportar a sujeira, não apará-la.** Espaço e quebra de linha nas pontas não aparecem em campo de
senha, viajam no cabeçalho `Authorization` e devolvem o mesmo 401. Aparar em silêncio esconderia o
defeito, porque o worker usa o valor como está — a conferência aponta e segue diagnosticando, para
que ninguém corrija o espaço só para descobrir depois que a chave também era a errada.
`btrim` de um argumento apara **só espaço**: quebra de linha e tabulação passam direto, e são
justamente as que uma cópia de terminal traz. Quem pegou isso foi o teste, contra a primeira versão
da função.
**O arquivo é o procedimento, não o cofre.** `LIGAR.md` explica onde a chave mora e por que não pode
morar em arquivo — nem nele. A primeira anti-regra do projeto não abre exceção para documentação.

### D45 — Três dos quatro fatos do writeback nunca eram produzidos
Gatilhos em `enrollments` e em `suppression` enfileiram `respondido`, `campanha_concluida` e
`opt_out` na `outbox`. Antes só `identidade_invalida` nascia.
*Justificativa:* o D3 fixa o contrato em quatro fatos e o diagrama do `CLAUDE.md` desenha
`outbox → writeback CRM`. Conferindo o que o motor gravava: `identidade_invalida` em dois lugares, e
os outros três **em lugar nenhum** — a palavra só existia na definição do enum. O `'respondido'` que
aparece no código é `tipo_evento` de `message_events`, outro enum com a mesma palavra, e foi o que
fez a falta passar despercebida.
O estrago é concreto: quem pede para sair entra em `suppression` e o CRM nunca sabe, então o
corretor liga para quem pediu para não ser incomodado; quem responde encerra a cadência e continua
aparecendo como lead frio, o mais quente da base parado; a campanha termina e o lead fica "em
cadência" para sempre. É o formato do D31, do D37 e do D42 — a garantia escrita, a verificação
ausente —, só que aqui nem o produtor existia.
**Por gatilho, não por chamada.** Há dois caminhos de encerramento: `encerrar_enrollment` para o
agendador e o gatilho de `message_events` para a invariante 4. Um gatilho em `enrollments` pega os
dois; pedir a cada chamador que lembre de gravar o fato é a convenção que este projeto recusa em
todo lugar.
**Shadow mode não escreve no CRM.** Rodar o caminho inteiro sem efeito externo é o que `simulado`
significa, e o CRM é externo. Dizer a ele que a campanha concluiu, quando nenhuma mensagem saiu, é
uma mentira que o backfill não desfaz. O gate é a existência de mensagem não-simulada — e ele
resolve de graça o caso do D35: enrollment que percorreu todos os passos sem identidade nenhuma
encerra em `fim_dos_passos` sem nunca ter contatado, e "campanha concluída" para quem nunca foi
contatado é exatamente o silêncio que a prévia da inscrição existe para quebrar.
**Dois motivos de encerramento não viram fato, cada um por uma razão.** `mudanca_etapa_crm` veio do
CRM — escrever de volta é o eco que o D3 manda evitar. `falha_permanente` não tem fato no contrato
estreito, e alargar o contrato é decisão, não detalhe de implementação.
**`respondido` e `opt_out` são fatos da pessoa**, não do enrollment: índice parcial único garante um
por contato enquanto o anterior estiver pendente. Uma resposta encerra todos os enrollments do
contato, e sem isso quem está em três campanhas geraria três escritas idênticas no CRM.
**Ainda falta o consumidor.** Nada drena a `outbox` — `status_outbox` tem `enviado` e `falha` que
ninguém escreve, e `tentativas`/`proxima_tentativa_em` são maquinaria de retentativa sem retentador.
O dreno precisa do OAuth do Pipefy, que mora em `_shared/pipefy.ts` do projeto legado e não está
neste repositório.

---

## Decisões adiadas (não decidir agora)

| Tema | Por que esperar |
|---|---|
| RCS | Exige agente verificado junto a agregador/operadoras. Adapter previsto na interface; implementar quando houver volume que justifique o processo. |
| Volumes-alvo e quotas por remetente | Dados virão do shadow mode. Decidir antes é chute. |
| Telas de operação e relatórios | Reversível. Depende de como o flow se comporta em produção. |
| Construtor visual de flows | Só faz sentido quando o time comercial precisar editar (hoje não precisa, D9). |
| Resposta "PARE" virar supressão | Hoje a resposta encerra o enrollment (invariante 4) mas **não** suprime, então a campanha seguinte volta a falar com a pessoa. Detectar opt-out em texto livre é decisão de produto, e há agentes de IA no schema para isso. A porta de entrada manual já existe (D41). |
| Denúncia de spam e bounce virarem supressão | Hoje `email.complained` e `email.bounced` gravam `rejeitado` e param aí. Transformar em `suppression` é decisão de produto — vale para os quatro canais, não só e-mail, e endereço suprimido não volta. Decidir com o primeiro volume real de campanha fria. |

---

## Spikes abertos

**S1 — Capacidade e queima do UAZAPI.** Qual volume por chip, com que taxa de banimento e qual custo
por remetente. Experimento de ~2 semanas. Não bloqueia o motor.

**S2 — Warm-up de domínios de e-mail.** Provisionamento é o caminho crítico mais longo do projeto
(3–6 semanas de calendário, independente de código). **Iniciar imediatamente, em paralelo à Fase 0.**

**S3 — Viabilidade de cold DM no Instagram.** Medir taxa de conta queimada e custo de manutenção.
Se viável, entra depois como pool de remetentes — a interface já estará pronta.

---

## Ordem de execução

| Fase | Entrega | Risco |
|---|---|---|
| 0 | ✅ Inventário read-only — `INVENTARIO-FASE-0.md`: 83 edge functions e 52 tabelas classificadas | Nenhum |
| 2 | Schema novo com invariantes garantidas por constraint/trigger + backfill de contatos com dedup | Baixo |
| 1 | Interface `ChannelAdapter` sobre os 5 provedores reais (Evolution, Meta Cloud, Gupshup, Twilio, Z-API/360dialog) sem mudar comportamento — ver D12 | Muito baixo |
| 3 | **Shadow mode**: motor calcula e grava tudo como `simulado`, não envia. Compara com o Disparador atual | Nenhum — de-risca tudo |
| 4 | Cutover por campanha, começando por resgate (D5) | Controlado |
| 5 | Deletar o caminho antigo — **com data definida** | Baixo |

---

## O que sobrevive da codebase atual

**Migra quase intacto:** clientes de provedor (Gupshup, Comtele, UAZAPI), `_shared/pipefy.ts` com
OAuth client_credentials, classificador da Ana (vira detecção de resposta), gate de blacklist,
padrão de secrets no Vault, UX do Disparador (upload multi-formato, modos de disparo, resumo por IA).

**Descarta:** modelo de execução em lote, status-como-mutex entre camadas, qualquer tabela modelada
por canal.

### D46 — O dreno da outbox, e o que um dreno parado parece

O D45 fez os três fatos nascerem. Ninguém os consumia. As linhas entravam `pendente` e ficavam ali.

Pior: `tentativas`, `proxima_tentativa_em` e `ultimo_erro` existem na `outbox` **desde a primeira
migration**, e nenhum SQL do projeto jamais as escreveu. É a forma exata do `tem_adapter` do D31 —
coluna que parece garantia e é decoração. A tabela estava vestida de fila com retry sem nunca ter
tido um consumidor.

O dreno é o análogo exato do despacho de mensagens, e isso é escolha, não coincidência:

| | reivindicar | fechar |
|---|---|---|
| `messages` | `reivindicar_pendentes` | `registrar_resultado_envio` |
| `outbox` | `reivindicar_writebacks` | `registrar_resultado_writeback` |

Mesmo lease, mesmo `FOR UPDATE SKIP LOCKED`, mesma casa (`public` com EXECUTE só para
`service_role`, que é o que permite o worker chamar por PostgREST sem expor nada ao cliente).

**O que este D46 não entrega.** Falar com o CRM. O adapter do Pipefy depende do OAuth de
`_shared/pipefy.ts`, que mora no projeto legado. A divisão é a mesma do agendador e dos `adapters/`:
a decisão e a reivindicação são atômicas e ficam no banco; o I/O é de quem tem a credencial. Assim
como o `instagram_oficial` está no catálogo com `tem_adapter = false`, aqui a ausência é declarada
em vez de fingida.

#### Três coisas que o dreno podia quebrar, e não quebra

**1. Reivindicar não pode reabrir a porta que o D45 fechou.** A trava de dedup do D45 é um índice
único **parcial** em `status = 'pendente'`. Se reivindicar tirasse a linha de `pendente` — o reflexo
natural de "peguei, então não está mais na fila" — um segundo `respondido` da mesma pessoa entraria
enquanto o primeiro ainda estava em voo, e o CRM levaria a escrita duas vezes. A linha reivindicada
continua `pendente`; quem a segura é o `reivindicada_em`. A sabotagem que troca isso derruba quatro
asserções.

**2. Desistir não pode ser silencioso.** No oitavo tropeço a linha vira `falha` e o fato **nunca
chega ao CRM**. Se ninguém puder listar o que desistiu, é o D45 repetido uma camada acima: o fato
existe, a garantia está escrita, e a verificação não existe. Por isso `writebacks_falhados` diz
quais são, de quem e por quê.

E `falha` **solta** a trava do D45, de propósito: o fato não chegou, então uma ocorrência nova da
mesma pessoa tem direito de tentar em vez de ser recusada por causa de uma linha morta.

**3. Dreno parado não pode parecer fila vazia.** É o D36 e o D44 outra vez, na terceira superfície.
"Zero writebacks saindo" tem duas causas opostas — nada aconteceu, ou o dreno morreu — e sem um
número que as separe as duas são a mesma tela. O número é `pendente_mais_antigo_em_horas`: fila
vazia **não tem** mais antigo. É o único campo do `resumo_da_outbox` que distingue as duas
situações, e é por isso que ele existe.

#### Verificação

`tests/dreno.sql`, 25 asserções. Quatro sabotagens conferidas uma a uma, porque asserção que o
cenário não consegue violar não prova nada (D36):

| sabotagem | o que fica vermelho |
|---|---|
| dreno ignora a hora marcada | "antes da hora marcada não volta ao lote" |
| reivindicar tira a linha de `pendente` | as quatro do item 1, inclusive a trava do D45 |
| teto que nunca chega | "no teto de tentativas, desiste" e as duas de visibilidade |
| `min(criado_em)` sem `FILTER` | "fila vazia: não existe mais antigo" |

#### E um achado de tabela ao lado: o suite dependia de estado ambiente

Ao cobrar a grade de privilégios das quatro funções novas, a asserção "as duas do worker seguem
chamáveis por `service_role`" me fez perguntar onde esse papel nasce. Resposta: em lugar nenhum do
repositório. O `tests/run.sh` cria `anon` e `authenticated`; `service_role` **existia por acaso** na
máquina onde os testes vinham rodando.

Consequência, confirmada escondendo o papel e rodando o suite: ele não roda. Estoura em
`tests/chave_do_motor.sql`, num `has_function_privilege('service_role', ...)`. E antes de estourar,
todos os `GRANT ... TO service_role` das migrations — que são guardados por
`IF EXISTS (SELECT 1 FROM pg_roles ...)` — eram **pulados em silêncio**, de modo que o suite
conferia uma grade mais estreita que a de produção.

Isto estava assim desde o D44, escondido por uma máquina que tinha o papel. É a mesma forma do
resto desta lista — a garantia escrita, a verificação ausente — com um agravante próprio: quem
verificava dependia de algo que não estava no repositório, então o suite verde não significava o
que parecia significar. O `run.sh` agora cria os três papéis, e o experimento foi refeito ao
contrário: papel escondido, suite verde, porque agora ele mesmo o cria.

A pergunta que fica registrada, do mesmo feitio da do D37: **o que mais o suite assume da máquina
em vez de montar?**

#### E uma correção minha, achada antes de construir em cima dela

As duas funções de leitura nasceram sem tenant na assinatura, contando só com o RLS. Fui construir
a tela e, ao olhar como `resumo_da_campanha` é chamada, vi que o padrão do projeto tem as **duas**
camadas: filtro explícito `WHERE tenant_id = p_tenant` **e** RLS por baixo, porque a função é
`SECURITY INVOKER`.

Ter só o RLS era frágil por dois motivos, e o segundo é o que pesa. O primeiro: o RLS é a camada 3
do D18 e não alcança todo papel — eu mesmo tinha concedido as funções a `service_role`, e aí a
mesma chamada teria duas semânticas. O segundo: duas funções de painel com contratos diferentes é
a segunda normalização do D32 em outra roupa. Quem escrever a terceira vai copiar uma das duas, e
não há como saber qual.

Corrigido: `resumo_da_outbox(p_tenant)` e `writebacks_falhados(p_tenant, p_limite)`. E, porque um
tenant só no banco não consegue violar a asserção (D36), o cenário agora tem um segundo cliente com
um writeback falhado — o caso mais perigoso, já que é o que a tela lista com nome e erro do
contato. Sabotar o filtro faz a asserção contar 2 onde o certo é 1.

#### A tela, que é o que torna tudo isso legível

Construí os números e quase parei aí — que é exatamente o erro que o D36 nomeia. `resumo_da_outbox`
existe para uma tela; sem ela, é uma função que ninguém chama.

A tela precisa separar **três** estados, e não dois, porque "zero writebacks saindo" tem três causas
que produzem a mesma ausência de sinal:

| estado | o que é | como se sabe |
|---|---|---|
| nada aconteceu | ninguém respondeu nem pediu para sair | total zero |
| **nada nunca saiu** | os fatos empilham e o dreno nunca rodou | `enviados = 0` |
| o dreno parou | já saiu antes, e agora empacou | `enviados > 0` e idade acima do teto |

O do meio é o estado de **hoje**, porque o adapter do CRM ainda não existe. E é por isso que ele
não pode ser vermelho: nesta fase a fila crescendo é o comportamento **correto** de um motor que
guarda o que descobriu enquanto o caminho de saída não existe. Pintar isso de alarme ensinaria a
ignorar o alarme — e aí o de verdade, o terceiro, passa despercebido. É a mesma razão do D36 ter
uma tela dizendo "todas em shadow mode" em vez de deixar parecer defeito.

Nenhum dos três é escrito à mão: os três saem de `enviados` e da idade do pendente mais antigo. E a
idade ser **nula** em vez de zero quando a fila está vazia é o que faz os dois últimos não se
confundirem — tratar nulo como zero silenciaria a parada de verdade; tratar como infinito alarmaria
a fila vazia. Ambos têm teste.

A decisão mora em `app/src/telas/situacao_do_writeback.ts`, fora do `.tsx`, porque é a parte que
pode estar errada — 7 testes, um por situação que, lida errado, some. O `.tsx` é só desenho.

**O que não foi verificado, e por quê.** A tela não foi renderizada no navegador. A política de rede
do ambiente nega tanto o host do Supabase quanto o preview do Vercel, então não há caminho: nem
rodando o app localmente (ele precisa do banco), nem abrindo o deploy. Não é escolha, é fronteira
do ambiente.

O que sobra dessa lacuna é risco de desenho, e esse foi conferido estaticamente: `tsc` e build
limpos, as classes que a tela usa (`tab`, `kpis`, `kpi`, `aviso`, `sec`, `mono`) existem no CSS, a
tabela é montada como `Campanha` e `Contatos` montam a delas, e o `Aviso` aceita as três variantes
usadas. A decisão dos três estados, que é a parte que pode estar logicamente errada, tem 7 testes.

### D47 — A campanha aponta o seu flow

Até aqui, `campaigns` e `flow_versions` só se encontravam dentro de `enrollments`. A dupla existia,
mas ninguém era dono dela.

A consequência aparecia na tela de contatos: para inscrever alguém, o operador escolhia a versão de
flow numa lista de **todas** as versões do cliente, e a tela mostrava os canais dos dois lados para
que ele mesmo reparasse se cruzavam. Isso é contorno, não solução — e o erro que ele evita é
silencioso, que é o pior tipo. Flow de e-mail numa campanha só de WhatsApp não dá erro nenhum: o
motor pula passo a passo e encerra como concluído sem mandar nada (D35).

**A pergunta "qual flow esta campanha roda" é da campanha, não de cada inscrição.** Perguntá-la a
cada inscrição é perguntar N vezes uma coisa que muda uma vez — e cada repetição é uma chance de
responder diferente.

#### Três decisões embutidas

**A coluna é NULL-ável.** Campanha existe antes de o flow estar escrito, e `criar_campanha_de_modelo`
cria a campanha e o flow em sequência. Exigir a ligação no INSERT inverteria essa ordem sem ganho.

**Apontar é um ato**, com função própria (`definir_flow_da_campanha`), porque é ali que a conferência
cabe: cruzar os canais uma vez, quando se liga, no momento em que quem configura ainda está olhando
para a tela de configuração. A recusa é só para a interseção **vazia**. Cruzamento **parcial** passa
de propósito — o D4 já manda pular o passo cujo canal a campanha não habilita, e flow multicanal em
campanha de um canal só é uso legítimo. Proibir o parcial seria uma trava estreita demais, que é o
outro jeito de errar.

**Repontar a campanha não move quem já está inscrito.** `enrollments` carrega o próprio
`flow_version_id` desde a primeira migration, e é ele que o agendador lê. Publicar versão nova segue
sendo o que o D9 diz: quem está em curso termina na versão em que entrou.

#### O que a sabotagem ensinou sobre a minha própria asserção

Quatro sabotagens, e a terceira não acendeu nada — o que era o sinal, não o alívio.

Tirando a checagem de "campanha sem flow" de `inscrever_pela_campanha`, quem barra no fim é o
`NOT NULL` de `enrollments.flow_version_id`. Como a asserção só aceitava `invalid_parameter_value`,
o `not_null_violation` passava por cima dela e **abortava o arquivo** — e teste que aborta encolhe
sem avisar (D38).

Duas correções, e a segunda importa mais:

- a asserção passou a capturar `others` e a distinguir *"recusou claramente"* de *"estourou cru,
  SQLSTATE 23502"*;
- **o comentário da migration passou a dizer a verdade menor.** Aquela checagem não impede estrago
  nenhum — o banco já impedia. O que ela acrescenta é a recusa **legível**: sem ela o operador
  recebe um erro citando uma coluna interna, que não diz o que fazer. Escrever que ela "impede o
  enrollment vazio" teria sido uma afirmação maior do que o código sustenta.

E uma correção menor no caminho: eu tinha posto `ON DELETE SET NULL` na FK. Mas `flow_versions` é
imutável por gatilho, então a cláusula é inalcançável — e `SET NULL` diria a coisa errada se um dia
rodasse, desapontando a campanha em silêncio. Ficou sem `ON DELETE`, com o motivo escrito, e com
asserção provando que apagar uma versão de flow é recusado.

### D48 — Quem pede para sair, sai

Até aqui, responder encerrava o enrollment (invariante 4) mas **não** suprimia. Quem respondia "pare"
saía daquela cadência e voltava a receber na campanha seguinte: o motor honrava a resposta e
esquecia o pedido.

#### Primeiro achado: o texto era jogado fora

Antes de escrever o detector, fui ver onde o texto da resposta chega. **Nenhum adapter guardava.** Os
cinco gravavam só metadado — `de`, `remoteJid`, `tipo_mensagem` — e o corpo da mensagem morria no
`normalizeWebhook`. Um classificador de opt-out em SQL não teria o que ler.

É o formato do D31 de novo, numa camada acima: eu teria construído a verificação sobre um campo que
não existia, e ela nunca dispararia — em silêncio.

Cobertura real, depois da correção:

| Canal | Resposta chega? | Texto? |
|---|---|---|
| WhatsApp (Gupshup, Meta, UAZAPI, Evolution) | sim | **sim, agora** |
| E-mail (Resend) | sim, `email.received` | corpo quando o provedor manda |
| **SMS (Comtele)** | **não** — `normalizeWebhook` devolve `[]` | não há entrada nenhuma |

O SMS merece destaque porque é o caso **clássico** de opt-out no Brasil: responder PARE a um SMS.
Hoje esse caminho não existe, e fingir que existe seria pior do que dizê-lo.

#### A armadilha, que neste negócio é cara

Supressão é **imutável**. E duas das palavras óbvias são ambíguas exatamente onde está o dinheiro:

- *"quero **sair** do meu plano da Amil"* — é intenção de troca de operadora. É o **melhor lead que
  existe**, não um opt-out.
- *"**não quero** individual, quero empresarial"* — é resposta de compra.

Suprimir esses dois seria perder a venda **e** fazer o oposto da vontade da pessoa.

A regra que resolve: termo ambíguo só conta com **contexto de recebimento nas três palavras
seguintes**. "não quero **receber**", "sair da **lista**". Termo sem outra leitura possível numa
resposta a prospecção — "pare", "descadastrar", "não perturbe" — vale sozinho.

Três detalhes que a implementação obrigou a enfrentar:

- **Contexto que vem antes.** "pode descartar" traz o sentido no que vem antes do termo. Resolvido
  com termo composto (`pode descartar`), e não com uma segunda janela para trás — a busca já prefere
  o termo mais longo.
- **"para" é a preposição mais comum do idioma.** Só a construção `para de` conta, e ainda assim com
  contexto de envio, senão "liga para de manhã" suprimiria alguém.
- **"tira" também é ambíguo**: *"me tira uma dúvida"* é engajamento puro.

A assimetria que governa tudo isto: **falso positivo é irreversível; falso negativo se conserta pela
tela de supressão.** Quando os dois erros custam diferente, a trava mora do lado do erro caro.

#### Verificação

`tests/opt_out.sql`, 13 asserções, mais 7 nos adapters. Duas listas de frases, e a segunda é a que
importa: dezesseis pedidos de saída que **têm** de ser pegos, e dez leads vivos que **não** podem
ser suprimidos — cinco dos quais contêm literalmente um termo da lista.

Três sabotagens. A primeira é a que justifica a decisão inteira: **tirando a regra de contexto,
sete dos dez leads vivos do cenário são suprimidos**, entre eles "quero sair do meu plano da Amil" e
"quero parar de pagar tão caro, tem opção melhor?".

E uma correção numa asserção minha: eu tinha fixado qual termo a frase de teste casaria. "pode parar
de me mandar mensagem" casa tanto `parar` (com contexto "mandar") quanto `para de`, e as duas
leituras estão certas — a asserção passou a exigir que o motivo carregue **um termo real da lista**,
que é a propriedade auditável, em vez de um termo específico.

#### Onde mudar

A lista mora em `opt_out_termos`, com uma coluna `nota` em cada linha explicando por que o termo
está lá e por que exige (ou não) contexto. Trocar vocabulário não é mexer em código. A tabela não
tem `tenant_id` de propósito — é idioma, não dado de cliente — e está na lista de exceções do
meta-teste com essa justificativa escrita.

### D49 — Devolução e denúncia não são a mesma coisa

A operação pediu que "bounce e denúncia também suprimam". Suprimem — mas de formas diferentes,
porque são fatos de naturezas diferentes, e tratá-los igual escreveria no CRM uma vontade que
ninguém manifestou.

| | O que é | Suprime | O CRM ouve |
|---|---|---|---|
| **denúncia** | vontade: a pessoa marcou como spam | a **pessoa**, em todo canal | `opt_out` |
| **devolução permanente** | fato sobre o endereço: a caixa não existe | só **aquele endereço** | `identidade_invalida` |
| **devolução temporária** | caixa cheia numa terça-feira | **nada** | nada |

#### O que já existia, e estava colapsado

`tipo_evento` tinha `rejeitado` — recusa **na hora do envio**, síncrona. Não tinha nada para o
assíncrono. E o adapter da Resend mapeava **`email.bounced` e `email.complained` para o mesmo
`rejeitado`**, apagando justamente a diferença que decide qual fato vai para o CRM.

Havia até um teste afirmando isso: *"resend: bounce e denúncia de spam viram rejeitado"*. O teste
**codificava o defeito** — passava todo dia, e o que ele garantia era que a fusão continuasse.
Foi reescrito para cobrar a distinção.

#### A composição que saiu de graça

Devolução não produz `opt_out` **não** por um `IF` que alguém lembrou de escrever, mas porque o
gatilho de writeback do D45 volta cedo quando `contact_id` é nulo — e supressão por **endereço** tem
`contact_id` nulo. As duas formas de suprimir já eram estruturalmente diferentes; bastou usar a
certa em cada caso.

#### Uma justificativa minha que estava errada, e o teste que a derrubou

Escrevi que suprimir o endereço servia para **sobreviver à reimportação**. O teste estourou com
`duplicate key`: `contact_identities` é única em `(tenant, canal, valor_norm)` e a ingestão usa
`ON CONFLICT DO NOTHING`. A linha invalidada persiste. Minha razão era falsa.

A razão verdadeira é o **D37 aplicado a identidades em vez de remetentes**: invalidar decide o
**futuro**, e a mensagem que já existe carrega a identidade na própria linha. Entre o agendador criar
a mensagem e o despachante pegá-la há uma janela ilimitada, e é dentro dela que a devolução chega.
Quem barra a mensagem em voo é `esta_suprimido`, que o despacho consulta (D39) — `valida` ele nem
olha.

Sem a supressão por endereço, essa mensagem sai para uma caixa morta. Em e-mail isso não é só
desperdício: devolver de novo derruba a reputação do domínio, que é o ativo que faz as próximas
chegarem.

O teste passou a encenar exatamente essa janela — passo 2 pendente, devolução do passo 1, e a
asserção de que o despachante cancela.

#### O default do desconhecido

Provedor que não diz se a devolução foi permanente cai no caso **temporário**. É a mesma assimetria
do D48: falso negativo se conserta pela tela; falso positivo é imutável. O teste cobra os três
jeitos de o provedor não dizer — campo ausente, nome de campo trocado, valor inesperado.

#### Verificação

14 asserções em `tests/devolucao.sql` e 2 novas nos adapters. Duas sabotagens: fundir os dois faz o
CRM ouvir `opt_out` por um bounce (cinco asserções vermelhas); ignorar `permanente` suprime endereço
bom por caixa cheia (três vermelhas).

### D50 — O link de acesso voltava para o localhost

Relato da operação: o link que chega por e-mail redirecionava para `localhost` em vez do endereço
da plataforma.

A primeira coisa foi olhar o código, e **ele estava certo**: `Entrar.tsx` já passava
`emailRedirectTo: window.location.origin`. O defeito não estava aqui.

O Supabase só honra o `emailRedirectTo` se a URL estiver na lista de **Redirect URLs**. Quando não
está, ele **não recusa e não avisa** — cai em silêncio no **Site URL**, que vem de fábrica como
`http://localhost:3000`. Confirmado na documentação, que tem uma página de troubleshooting com
exatamente este título. Há um segundo suspeito possível: o template do Magic Link usando
`{{ .SiteURL }}` em vez de `{{ .RedirectTo }}`, que ignora o pedido por construção.

Nenhum dos dois é código deste repositório — são painel. E é aí que está a parte que **é** minha.

#### É o D44 de novo, e por isso rendeu código

O sintoma tem a forma que este projeto já catalogou duas vezes: **a requisição dá certo**. `error` é
nulo, a tela diz "link enviado", e não há nada para suspeitar. O erro só aparece minutos depois, na
caixa de entrada, sem nada que ligue uma coisa à outra — e o primeiro palpite de quem recebe é o
filtro de spam ou o navegador, não uma lista dentro de um painel.

O app não tem como saber o que está na lista do Supabase. Mas tem como dizer **o que pediu**. A tela
de entrada agora mostra, depois de enviar, o endereço para onde o link deve voltar — e, quando esse
endereço não é local, explica onde arrumar se o e-mail apontar para outro lugar. Mistério vira
diagnóstico de cinco segundos.

#### Dois detalhes que o trabalho obrigou

**A barra no fim.** `window.location.origin` não tem barra, e o glob `.../**` da lista do Supabase
casa caminhos **abaixo** da raiz. Mandar a origem pelada deixa o casamento na dependência de
detalhe de implementação do glob. `urlDeRetorno` garante a barra.

**`ehLocal` por regex ancorada, e não por `includes`.** `https://localhost.exemplo.com` contém a
palavra "localhost" e é um endereço real — um `includes` esconderia o aviso exatamente de quem mais
precisa dele. Tem teste para os dois lados.

#### Um erro meu, que o CSS não reclamaria

Escrevi `var(--linha)` no estilo da nota. O token não existe — o nome real é `--line`. CSS não
falha: a borda simplesmente não apareceria, e o build passa verde. Corrigi e varri o arquivo inteiro
atrás de outros (`nenhum`). É a mesma classe do D31: uma referência que parece garantia e não é
lida por ninguém.

### D51 — O que está publicado confere com o repositório?

Fui publicar as edge functions com o código do D48 e do D49 e parei no meio, por dois motivos que
valem mais que o deploy.

#### O primeiro: a pergunta não tinha dono

`LIGAR.md` dizia **"Já feito em 23/09. As três estão na versão 2, conferidas byte a byte"**. Era
verdade quando foi escrito e ficou falsa no dia em que `adapters/` mudou — hoje. Ninguém reparou,
porque nada reparava: é a mesma classe do contador de migrations que ficou nove atrás e do
`tem_adapter` do D31.

`supabase/functions/conferir-publicado.py` responde a pergunta em vez de alguém lembrar dela. Para
cada function, resolve o **fecho transitivo dos imports** — que é exatamente o que vai no bundle —
tira um digest do conteúdo, e compara com `PUBLICADO.json`. Mudou uma linha de qualquer arquivo
empacotado, fica vermelho. Roda dentro de `tests/run.sh`.

Ele **não** confere o que está no Supabase; isso precisa de rede, que o suite não tem. Confere se
alguém **disse** ter publicado o que está aqui. Publicar sem registrar dá vermelho; registrar sem
publicar é mentira deliberada, e para isso não há verificação que ajude.

A porta de escape é a do meta-teste de tenant: dá para marcar `pendente`, mas é preciso escrever o
motivo — e aí ele aparece em toda rodada, que é o oposto de esquecer.

#### O segundo: transporte manual de 70 KB é o D32 esperando acontecer

Não há token de CLI no ambiente, então publicar significa eu reproduzir 15 arquivos — 70 KB de JSON
— exatos, numa chamada. O D32 nasceu de um transporte mexendo numa barra invertida. Serializei
mecanicamente para tirar o risco do arquivo, e o risco continuou onde importa: na reprodução.

Contra isso, o que o deploy compraria **hoje** é nada. Não há tenant, remetente, chave nem job: nenhum
webhook pode chegar. E publicar agora resolveria uma vez, enquanto a próxima mudança em `adapters/`
recriaria o mesmo buraco — o verificador resolve para sempre.

Então: verificador agora, deploy no `LIGAR.md`, junto de ligar o motor, que é quando passa a
importar.

#### O erro que eu quase cometi dentro da própria correção

Ao gravar o `PUBLICADO.json`, registrei `motor-worker` e `provisionar-instancia` com **o digest de
hoje** e a data 23/09 — ou seja, afirmei que o publicado batia. Elas também empacotam os adapters
que mudaram; o digest delas também está diferente. Eu teria mentido no arquivo construído para
impedir mentiras, e a mentira teria passado verde.

Corrigido: as três estão `pendente`, com a diferença dita — só a `canal-webhook` muda
**comportamento**, porque é a única que chama `normalizeWebhook`; as outras duas diferem na fonte e
são equivalentes na prática. E o digest gravado virou `desconhecido-pre-D48` em vez de um número
inventado, porque o digest da época não foi registrado e não dá para recomputá-lo.

#### O que está em jogo até publicar

Enquanto a `canal-webhook` não for republicada, **quem responder "pare" não é suprimido e devolução
não é distinguida de denúncia** — em silêncio. Está escrito no `LIGAR.md`, no passo que precede
ligar o motor.

### D52 — Publicadas, e a prova de que foram

O D51 adiou o deploy e construiu o verificador, com um argumento: sem CLI, publicar é reproduzir
70 KB exatos, e o que isso compraria hoje era nada. O argumento tinha prazo — ele valia enquanto
nada dependesse do deploy, e o passo 4 do `LIGAR.md` depende. Publiquei as três.

#### O que torna aceitável um transporte que passa por mim

Não é cuidado ao copiar. É **ler de volta e comparar**, que é a mesma ideia do digest estrutural do
schema: o que prova que o publicado é o do repositório é a comparação, não a intenção de quem
publicou.

Então cada function foi publicada e, em seguida, buscada de volta do projeto e comparada arquivo
por arquivo. O resultado:

| function | versão | verify_jwt | arquivos do bundle | idênticos |
|---|---|---|---|---|
| `canal-webhook` | 3 | `false` | 14 | 14 |
| `motor-worker` | 3 | `true` | 14 | 14 |
| `provisionar-instancia` | 3 | `true` | 13 | 13 |

`verify_jwt = false` na `canal-webhook` foi preservado de propósito e conferido na volta: provedor
não tem JWT para mandar, e o padrão valendo ali faria todo webhook voltar 401 — a invariante 4
parando de valer em silêncio, que foi o D23.

A comparação virou arquivo: `supabase/functions/conferir-contra-projeto.py`. Ela precisa de rede,
então **não** entra no suite — é o passo que se roda na hora de publicar, e é o irmão do
`conferir-publicado.py`, que roda sem rede e responde outra pergunta. A diferença entre os dois é o
ponto: um confere que alguém **disse** ter publicado o que está aqui; o outro confere o que o
projeto **tem**.

#### Uma descoberta que o D51 não previa

O fecho de imports do `conferir-publicado.py` acusa 15 arquivos na `canal-webhook`; o projeto
devolveu 14. O que falta é `motor/porta.ts`, e não é perda: ele só é importado como
`import type { Banco } from './porta.ts'`, e o bundler apaga import de tipo. Foi enviado e não
voltou porque nunca fez parte do bundle — e é por isso que a v2 também não o tinha, o que eu tinha
lido, antes de entender, como sinal de bundle incompleto.

O fecho segue sendo o certo para o digest: ele é conservador na direção segura. Mudar um arquivo
de tipos pode não mudar o bundle, e aí o verificador pede uma republicação que não era necessária —
barato. O contrário, ignorar imports de tipo e perder um arquivo que **é** empacotado, seria o
digest passando verde sobre uma diferença real.

O comparador conhece essa assimetria e a nomeia: arquivo ausente do bundle não é divergência;
divergência é arquivo que voltou diferente, ou arquivo no projeto que não existe no repositório.

#### O que isto destrava

Até agora, responder "pare" não suprimia ninguém e devolução não era distinguida de denúncia —
o código do D48 e do D49 existia no repositório e não no ar. Agora está no ar. O passo 4 do
`LIGAR.md` deixa de ser bloqueio para ligar o motor, e o que resta ali é tudo o que depende de
acesso que eu não tenho: o cliente, a chave e o remetente.

### D53 — O tenant de teste, e por que não existe "root"

Você pediu um admin/root nosso para testar. Duas correções antes de fazer, porque as duas mudam o
que foi feito.

#### O usuário já existia; o tenant é que não

`admin@grupoafx.com.br` está em `auth.users` desde o começo, confirmado, com senha, e entrou duas
vezes hoje (17:33 e 02:30 — são os logins que apareceram na investigação do D50). Não havia nada a
criar ali.

O que não existia era o **tenant**: zero linhas em `tenants` e zero em `tenant_users`. Entrar no
app com essa conta daria uma tela vazia, e o motivo não é bug — é o RLS fazendo o que deve. A
política de `tenants` é `pertence_ao_tenant(id)`, e quem não está em `tenant_users` não enxerga
linha nenhuma, de tabela nenhuma.

Isso também é o passo 1 do `LIGAR.md`, que estava parado esperando alguém com acesso de escrita.

#### Não há root neste produto, e isso é a arquitetura funcionando

Não existe papel acima do tenant. Os papéis são `dono`, `admin`, `operador` e `leitor`, e todos
valem **dentro de um tenant** (D18). Um usuário que enxergasse todos os tenants seria exatamente o
"bug entre clientes" que a `tenant_id` em toda tabela, as FKs compostas e o RLS por papel existem
para tornar impossível.

O equivalente ao que você pediu é **`dono` do tenant**, que é o papel máximo que o produto tem, e é
o que a conta recebeu.

#### O zero que quase não foi zero

Contei `tenants` e li 0 — e quase segui em frente. Mas `tenants` tem `FORCE ROW LEVEL SECURITY`, e
uma leitura sem JWT devolve zero linhas quer a tabela esteja vazia, quer esteja cheia. As duas
situações são indistinguíveis pelo `count(*)`, que é a forma do D44 outra vez.

Conferido por duas vias antes de escrever: o papel da consulta tem `rolbypassrls = true` (então o
RLS não estava filtrando), e `pg_stat_user_tables.n_live_tup` também dizia 0, que é um caminho que
não passa por política nenhuma. Criar um segundo tenant por causa de uma leitura filtrada teria
falhado no `UNIQUE` do slug — de sorte, não de cuidado.

#### Onde o bootstrap mora, e por que não no repositório

O tenant nasceu de um `DO` idempotente aplicado **só no projeto**, não versionado. Isto é dado, não
schema: o repositório não carrega o uuid de uma pessoa real, e um ambiente novo — o banco
descartável do suite, um clone futuro — não precisa deste tenant nem teria o schema `auth` para
satisfazer a checagem de dono. É o mesmo tipo de desvio que o `CLAUDE.md` já registra entre as 36
migrations do repositório e os registros do projeto, e entrou na mesma lista com o mesmo motivo
escrito.

A checagem de dono não é zelo: `criar_tenant` sem dono cria um tenant que **ninguém enxerga**, pela
mesma política de RLS de duas seções acima. Falhar alto é melhor do que criar o invisível.

| | |
|---|---|
| tenant | `1a9e60a5-49f4-431a-ab82-5a07adeb627f` |
| nome | Afinix Corretora (teste) |
| slug | `afinix-teste` |
| dono | `admin@grupoafx.com.br` |

Slug com `-teste` de propósito: o que for exercitado aqui é descartável, e o tenant de produção
nasce limpo quando for a hora — sem contato de teste, sem campanha de teste, sem supressão de
teste, que é imutável e não se apaga.

#### O que ainda impede de usar

Entrar no app ainda depende da lista de endereços do Supabase (D50): o link chega apontando para
`localhost:3000`. O tenant existir não conserta isso — são dois bloqueios independentes, e este era
o que estava do meu lado.

---

### D54 — Você conseguia começar e não conseguia parar

**Contexto.** Com o tenant de teste criado e o Hub abrindo, a pergunta deixou de ser "o schema está
certo" e passou a ser "o produto faz o que promete". A auditoria das quatro vertentes — UI, canais,
alocação de remetente, esquema de flows — achou quatro buracos, e os quatro são da mesma família:
**o motor sabia fazer, e nenhuma tela mandava.**

#### 1. Os três freios existiam e ninguém os puxava

`processar_vencidos` pula campanha com `ativa = false` desde a primeira migration. Pula enrollment
`pausado`. `remetentes_disponiveis` pula conta fora do estado `ativo`. Os três estão testados desde
sempre — e **nenhuma tela escrevia nenhuma das três colunas.** Dava para começar uma cadência pelo
produto e não dava para pará-la sem abrir o painel do Supabase, que é justamente o que o D26 diz
que o produto não pode exigir.

O RLS já autorizava: `pode_operar` para campanha e enrollment, `pode_administrar` para remetente.
Pelo D41, então, a tela escreve **direto na tabela** — criar `pausar_campanha()` em `public` seria
repetir em PL/pgSQL o que a política já diz.

#### 2. Mas o privilégio por baixo da política estava largo

Aqui o conserto virou outra coisa. A grade que o Supabase instala por padrão dá `UPDATE` de
**tabela inteira** ao papel `authenticated`, e **RLS decide quais LINHAS, nunca quais COLUNAS.** Um
cliente autenticado do próprio tenant podia, por uma chamada de PostgREST:

| o que | por que importa |
|---|---|
| `UPDATE sender_accounts SET enviados_na_janela = 0` | a invariante 3 furada **por fora** do motor: manda-se o dobro da quota |
| `UPDATE enrollments SET next_run_at = ...` | escolher quando o agendador dispara |
| `UPDATE enrollments SET passo_atual = ...` | escolher **o que** ele dispara |
| `UPDATE campaigns SET tipo = 'morna'` | mudar o pool permitido (D4) sem tocar em remetente nenhum |

Nada disso nasceu com a tela de ligar/desligar. A tela só foi a primeira vez que alguém precisou de
**uma** dessas colunas — e foi a hora de parar de dar as outras vinte junto. A grade passou a ser
por coluna:

```
campaigns        → (nome, objetivo, ativa, flow_version_id)
enrollments      → (status)
sender_accounts  → (apelido, quota_diaria, estado)
```

Encerrar um enrollment à mão continua impossível, e **não por grant**: o CHECK
`enrollments_encerramento_coerente` exige que `encerrado` venha com `encerrado_em` e
`motivo_encerramento`. Sem privilégio nessas duas colunas, o `UPDATE` que tentar
`status = 'encerrado'` bate no CHECK — e ressuscitar um encerrado bate no mesmo CHECK pelo outro
lado. Encerramento é fato do motor, e agora é fato do motor **por construção**.

#### 3. E o vizinho, que só apareceu ao conferir

Conferir a grade no projeto depois de aplicar mostrou o que estava ao lado: `messages`,
`message_events` e `outbox` continuavam com INSERT, UPDATE e DELETE de tabela inteira — e nenhuma
tela jamais escreveu em nenhuma das três. O que isso deixava fazer:

- `UPDATE messages SET status = 'enviado'` numa `pendente`: a mensagem nunca sai e o painel diz que
  saiu. Ao contrário, `enviado` → `pendente` é despachar de novo, a invariante 1 furada por fora;
- `UPDATE messages SET conteudo = ...` numa que está na fila: o texto que o shadow mode mostrou
  (D42) não é o que vai sair;
- `INSERT INTO message_events (tipo = 'respondido')`: o gatilho `encerrar_por_resposta` encerra a
  cadência inteira de quem não respondeu nada. **A invariante 4 disparada por quem quiser**;
- `INSERT INTO outbox`: escrever no CRM do cliente um fato inventado, pela porta que o D3 abriu
  justamente para ser estreita.

Revogado o INSERT/UPDATE/DELETE das três, `SELECT` mantido (a tela da campanha lê mensagem e
evento). Antes de revogar, conferida uma a uma cada função que escreve nelas: todas são do worker, e
`authenticated` não pode executar nenhuma.

Fechar `enrollments.next_run_at` e deixar `messages.status` aberta seria trocar de porta, não
fechar.

#### 4. A campanha nascia sem flow

O D47 deu à campanha a coluna `flow_version_id` e o ato de apontá-la — e deixou de fora o único
lugar do produto que cria os dois lados na mesma chamada. `criar_campanha_de_modelo` cria campanha,
flow, versão e passos, **devolve os dois ids, e não os liga.** Toda campanha nascida pelo Hub
nascia órfã.

O efeito é do tipo que este arquivo já catalogou: campanha sem flow não dá erro na tela; ela faz
`inscrever_pela_campanha` recusar quando alguém finalmente for inscrever — depois de importar a
planilha, depois de escolher os contatos. É a pergunta do D47 ("qual flow esta campanha roda")
respondida com "nunca".

A ligação passou a ser feita **chamando `definir_flow_da_campanha`**, e não com um `UPDATE` ali
dentro: a conferência de canais do D47 mora nela. Cruzar não pode falhar neste caminho — os passos
foram filtrados justamente pelos canais da campanha — e é por isso que chamar custa nada e repetir
a regra custaria a próxima divergência entre as duas cópias.

E dentro da função, não na tela, porque `tests/tenants.sql` e o backfill chamam
`criar_campanha_de_modelo` direto: ligar do lado de fora deixaria esses caminhos com o defeito, e
deixaria uma janela — criou, caiu a rede, campanha órfã — que dentro da função não existe.

#### 5. O trio do D47 não tinha consumidor

`definir_flow_da_campanha`, `inscrever_pela_campanha` e `prever_inscricao_pela_campanha` estavam
escritas, testadas, com `EXECUTE` concedido a `authenticated` — e **zero chamadas no app**. A tela
de contatos continuava pedindo a versão de flow numa lista de todas as versões do cliente, com o
canal escrito dos dois lados para a pessoa mesma reparar se cruzavam. Era o contorno que o D47
existe para remover, sobrevivendo ao D47.

Agora a tela da campanha aponta o flow (uma vez), e a tela de contatos só **mostra** qual é.

#### 6. "Resgate por Direct" era oferecido e não podia enviar

O Hub oferecia um modelo só de Instagram num catálogo onde nenhum provedor de Instagram tem
adapter. Criar funcionava, inscrever funcionava, e o motor adiava passo a passo para sempre.

O cruzamento agora é feito **antes de oferecer**, e separa dois "não" que não são o mesmo:

- **`sem_adapter`** — nenhum provedor do canal sabe enviar. Não é configuração que falta, é código
  que não existe (D30). O modelo aparece marcado e não abre.
- **`sem_remetente`** — o canal sabe enviar, este cliente ainda não tem conta. Abre, com aviso:
  criar a campanha antes de cadastrar o chip é ordem legítima de trabalho.

Fundir os dois num "indisponível" mandaria a pessoa procurar uma configuração que não existe.

#### 7. E a pergunta que ninguém tinha feito: as duas listas concordam?

`channel_provider_catalog.tem_adapter` é o que o pool lê (D31). `adapters/registro.ts` é o que o
despachante consulta. Duas listas escritas à mão, em linguagens diferentes, e **nada as comparava.**
As duas divergências possíveis falham de jeitos opostos:

- `tem_adapter = true` sem entrada no registro → o pool oferece, o despachante levanta "provedor sem
  adapter" na hora do envio, e fica como falha **da mensagem**, não como erro de cadastro;
- entrada no registro com `tem_adapter = false` → o adapter existe, funciona, e o pool nunca oferece
  a conta. O passo é adiado para sempre e **nada aparece como erro**.

`tests/registro_para_sql.ts` deriva a tabela do próprio `PROVEDORES_POR_CANAL` e compara, pelo mesmo
padrão de `planilha_para_sql.ts`. O `smtp` cai do lado certo pela regra, não por exceção escrita —
que é o que prova que a regra está certa.

#### O que este D repete dos anteriores

Três coisas, e todas já estavam escritas aqui:

1. **Coluna que ninguém lê é decoração** (D31, D46). `ativa`, `status = 'pausado'` e
   `estado = 'desativado'` eram três `tem_adapter` esperando.
2. **Falha silenciosa é pior que exceção** (D35, D45, D47). Campanha órfã, modelo sem adapter e
   registro divergente não dão erro nenhum — dão campanha "concluída" sem mensagem.
3. **Ao abrir uma porta, olhar as vizinhas.** A grade de `enrollments` só vale se a de `messages`
   também valer. É o "o que mais assume que ele é curto?" do D37, aplicado a privilégio.

#### O que fica para depois

Restam tabelas com `UPDATE` de tabela inteira para `authenticated` que nenhuma tela escreve —
`contacts`, `contact_identities`, `flow_steps`, `flow_versions`, `flows`, `agents`. Nenhuma delas
carrega estado do motor como as seis acima, e por isso não entraram agora: a regra a escrever é
"quem não escreve não tem privilégio", e ela merece uma passada própria, derivada do schema como os
três meta-testes do D18 — não uma lista à mão que envelhece sem avisar.

---

### D55 — Escrever a cadência, não só escolher um modelo

**Contexto.** A auditoria do D54 perguntava, entre outras coisas, se existia "o esquema de fluxos
para construir de acordo com os canais que queremos rodar". Existia — inteiro, desde a primeira
migration: `flows`, `flow_versions`, `flow_steps`, com a imutabilidade do D9 garantida por gatilho.
**O que não existia era porta.** A única forma de nascer um `flow_version` era
`criar_campanha_de_modelo`; o catálogo tinha sete receitas, e quem quisesse a oitava escrevia
`INSERT` à mão.

É a mesma forma do D41 (a supressão sustentava quatro decisões e não tinha como ser preenchida) e
do D54 (os três freios existiam e ninguém os puxava). A tabela certa, sem porta, é uma tabela vazia.

#### Publicar, nunca editar

`publicar_versao_de_flow` **só insere**. Não há `UPDATE` em `flow_versions` nem em `flow_steps`, e
não por disciplina: o gatilho `recusar_escrita` os recusa desde a primeira migration. "Editar a
cadência" é publicar a versão seguinte, e quem já está inscrito termina na versão em que entrou.

O teste que sustenta isso não olha a coluna — olha o **enrollment**. Publicar a v2 e conferir que
`enrollments.flow_version_id` continua na v1 é a prova; conferir que a função inseriu uma linha
nova não prova nada sobre o D9.

#### Publicar NÃO reponta

A decisão que mais valeu discussão. Depois de publicar a v2, a campanha continua rodando a v1 — e
isso é o comportamento correto, porque a v2 pode ter deixado de tocar um canal que a campanha
habilita, e a conferência que pega isso mora em `definir_flow_da_campanha` (D47), uma campanha de
cada vez.

Só que "correto e silencioso" é a combinação que este arquivo inteiro existe para evitar. A pessoa
edita o texto, publica, e vai embora achando que mudou algo. Então a função não reponta e a **tela
mostra quantas campanhas ficaram para trás**, com um botão por campanha. O que se evita é o
silêncio, não a troca.

#### Nada de cast em valor do cliente (D34, outra vez)

`'whatsap'::canal` aborta a chamada inteira com uma mensagem de Postgres sobre tipo de enum. Quem
está na tela precisa ler **qual passo** está errado e o que escreveu. Então o canal é casado contra
`pg_enum` e a recusa nomeia o índice: `passo 2: canal desconhecido (telegram)`. `atraso_horas` passa
por `^[0-9]+$` antes de virar número — o que também recusa o negativo sem depender do CHECK.

#### O atraso do primeiro passo é uma mentira que não se guarda

O agendador marca `next_run_at = now() + atraso do passo SEGUINTE`. O atraso do primeiro passo
**nunca é lido**: o primeiro disparo é o `next_run_at` que a inscrição gravou.
`criar_campanha_de_modelo` já gravava 0 ali; a função nova faz o mesmo, e a tela, em vez de um campo
desabilitado, escreve o fato — "assim que a inscrição vencer".

Aceitar um número que não tem efeito e devolvê-lo depois na tela é o mesmo defeito das colunas do
D46: parece garantia, é decoração.

#### A terceira lista que ninguém comparava

`privado.renderizar` decide, em SQL, o que é uma marcação num template: troca a chave conhecida e
**apaga** a que sobrou. A tela precisa da mesma decisão para dizer quais chaves o texto pede — e
escreveu a sua própria regexp em TypeScript.

Duas regexps à mão sobre a mesma regra é a forma exata do D32, uma camada acima. A divergência não
dá erro: a tela diria "todas as variáveis existem na base" sobre uma chave que o motor vai apagar, e
o contato receberia "Olá ,". Seria o D42 chegando tarde **porque o aviso que existe para chegar cedo
estava errado**.

`tests/variaveis_para_sql.ts` põe as duas uma contra a outra — não comparando as regexps, que
alguém pode reescrever, mas o **efeito** das duas sobre a mesma lista de textos. Sabotada com a
regexp sem `\s*`, caem dois casos: `{{ nome }}` com espaço, que o motor apaga e a tela não via.

E o outro lado do mesmo aviso: `variaveis_disponiveis` conta, no banco, quais chaves a base do
cliente realmente tem, com quantos contatos cada uma. Escrever `{{plano}}` quando a coluna é
`plano_atual` passa a ser visível **antes** de publicar, e não depois, na tela da campanha, quando o
template já rodou.

#### E o meta-teste cobrou o que eu tinha lido errado

A primeira versão desta migration concedeu `EXECUTE` das duas funções a `authenticated` e parou
por aí. O suite ficou vermelho numa asserção que não é sobre cadência nenhuma:

```
FALHA | anon não chama absolutamente nada em public | publicar_versao_de_flow, variaveis_disponiveis
```

A anti-regra do `CLAUDE.md` dizia "função nova não nasce com EXECUTE — conceder é decisão", e eu a
segui ao pé da letra. Ela estava **imprecisa**, e a imprecisão é exatamente onde o erro coube: no
Postgres, função nova nasce **sim** com `EXECUTE` para `PUBLIC`, e `anon` é membro de `PUBLIC`. O
que o D19 removeu foi o *default privilege* **nominal** que o Supabase instala (`GRANT ALL ON
FUNCTIONS TO anon, authenticated`), não o grant implícito do Postgres. Conceder a `authenticated`
sem revogar de `PUBLIC` antes é acrescentar um grant ao lado de uma porta que já estava aberta.

Na prática: `/rest/v1/rpc/publicar_versao_de_flow` respondia a visitante sem login. O RLS ainda
barrava a escrita — as políticas de `flows` e `flow_versions` pedem `pode_operar` —, então não era
gravação de estranho; mas `variaveis_disponiveis` só lê, e a lista de chaves de metadados de um
cliente não é coisa que se devolva a quem não entrou.

Duas coisas ficam disso. A anti-regra foi corrigida para dizer a forma exata, porque foi a leitura
dela que me levou ao erro. E o achado é do **meta-teste derivado do schema** (D18) — não de uma
lista de funções escrita à mão, que não teria a minha lá dentro. É o argumento do D18 se pagando
pela terceira vez.

#### O que este D repete

O mesmo de sempre, e vale escrever de novo porque foi a terceira vez em dois dias:

1. **Tabela sem porta é tabela vazia** (D41, D54).
2. **Correto e silencioso é a combinação a evitar.** Publicar sem repontar é certo; publicar sem
   dizer que não repontou é o D35.
3. **Duas implementações da mesma regra divergem, e divergem em silêncio** (D32, D54). A terceira
   ponte do suite nasceu por isso.
4. **Lista à mão não cobra o que você acabou de escrever** (D18, D31). Quem achou o `anon` aberto
   foi a asserção derivada do catálogo, e ela achou porque não precisa saber o nome da função.

#### Campanha em branco, porque escrever a cadência sem isso não fecha nada

Dar como escrever a própria cadência e deixar a criação de campanha só pelo catálogo é meio
caminho: o modelo traz tipo, base legal, canais e cadência num pacote, e quem escreveu a sua
precisava instanciar um modelo **qualquer** e repontar — ficando com o `template_slug` e a base
legal de um modelo que não é o dela.

`criar_campanha` existe por um motivo específico, e não por simetria: apontar o flow é uma **segunda
escrita**. Inserir a campanha pela tela (o que o RLS autorizaria, pelo D41) e chamar
`definir_flow_da_campanha` em seguida é a janela do D54 outra vez — criou, caiu a rede, campanha
órfã. Dentro da função as duas são uma transação só, e o apontamento é feito **chamando**
`definir_flow_da_campanha`, onde mora a conferência do D47. Aqui ela serve mais do que em
`criar_campanha_de_modelo`: lá os passos são filtrados pelos canais da campanha e cruzar é
garantido; aqui a pessoa escolheu as duas coisas separadamente.

A base legal é obrigatória, na função e na tela. Não é burocracia: é o que autoriza falar com a
pessoa, e o D4 a guarda na campanha para que a resposta exista por escrito quando alguém perguntar.
Um `NOT NULL` preenchido com espaço seria a decoração do D46.

#### E o que a tela passou a dizer sobre os agentes

Ao fechar o ponto 4 do D54 eu liguei a atribuição de agente por canal na tela da campanha e escrevi,
no aviso de canal sem agente, que *"o agente entra quando alguém responde"*.

Conferindo antes de construir a tela de agentes: **nada no motor lê `campaign_agents`.** Nem
adapter, nem edge function, nem função SQL do despacho. `agente_do_canal` tem grant e não tem
chamador; `agents.ai_credential_id` é preenchido com NULL na cópia do catálogo e ninguém o lê. A
resposta encerra a cadência pela invariante 4, e ninguém conversa depois.

Ou seja: a escolha grava a escolha, e é tudo. A frase que eu tinha escrito descrevia uma
funcionalidade que não existe — que é exatamente o `tem_adapter` do D31 com cara de recurso, e cujo
jeito de descobrir seria um lead sem resposta. O texto da tela foi corrigido para dizer isso em voz
alta.

Fica registrado aqui em vez de virar uma tela de edição de agente: escrever um editor para uma
persona que nenhuma parte do sistema consulta seria construir decoração com capricho. O laço de
conversa é decisão de produto e de modelagem — uma resposta do agente não cabe em `messages`, cuja
chave é `(enrollment_id, step_id)` —, e por isso não foi tomada de passagem.

---

### D56 — A resposta chegava, e ninguém conseguia ler

**Contexto.** Depois do D55 eu ia construir a tela de agentes. Antes, fui conferir quem consome o
que já existe — e a conferência achou duas coisas, uma que parou a construção e outra que a
substituiu.

#### A primeira: os agentes não têm consumidor

Nada no motor lê `campaign_agents`. Nem adapter, nem edge function, nem função SQL do despacho.
`agente_do_canal` tem grant e não tem chamador. `agents.ai_credential_id` nasce `NULL` na cópia do
catálogo e ninguém o lê. A resposta encerra a cadência pela invariante 4, e ninguém conversa depois.

Escrever um editor para uma persona que nenhuma parte do sistema consulta seria construir decoração
com capricho. Está registrado no D55 e na tela.

#### A segunda, que é a que importa

Os cinco adapters gravam o texto da resposta em `message_events.payload ->> 'texto'` desde o D48.
Contando quem lê esse campo: **um**, o classificador de opt-out, dentro do gatilho.
`eventos_da_campanha` devolve o TIPO do evento — `respondido` — e não o texto.

Então isto acontece hoje, com **tudo funcionando exatamente como projetado**:

1. a pessoa responde "quero entender a diferença de preço";
2. a invariante 4 encerra a cadência dela em todas as campanhas — correto;
3. o D48 confere se é opt-out e conclui que não é — correto;
4. a linha do tempo da campanha registra "respondido" — correto;
5. e **ninguém no produto consegue ler o que ela disse**.

Para ver a resposta era preciso abrir o painel do Supabase e escrever SQL, que é precisamente o que
o D26 diz que o produto não pode exigir.

É a forma do D42 com uma diferença que a piora. Lá, o texto ilegível era o que o motor **ia
mandar**, e o prejuízo era um template errado. Aqui é o que um lead **acabou de dizer**, e o
prejuízo é uma pessoa interessada esperando resposta que ninguém sabe que existe. Nenhum teste
falhava, nenhum alarme tocava: o caminho inteiro está certo, e o resultado é o lead perdido.

Vale a pena olhar a sequência dos três: o D48 fez o dado passar a existir, o D49 refinou o que ele
significa, e nos dois eu conferi o produtor. Nenhum dos dois perguntou **quem consome**. É a
pergunta do D46 — "nunca deixar um fato nascer sem quem o consuma" — e ela escapou duas vezes
seguidas no mesmo dado.

#### O que a função é, e o que ela não é

`respostas_recebidas(tenant, campanha opcional, limite)` devolve quem respondeu, por onde, em qual
campanha e passo, **o texto**, e — o que faz a diferença entre um lead e um processo — a mensagem
que provocou a resposta e se ela suprimiu a pessoa (D48, D49).

A mensagem anterior vai junto porque a resposta mais comum é a curta: "sim, pode ser" sem a
pergunta ao lado não quer dizer nada.

A supressão vai junto porque quem abre a caixa pode estar prestes a ligar de volta para alguém que
acabou de pedir para sair.

Campanha opcional porque são dois usos da mesma pergunta: quem olha uma campanha quer as dela, quem
abre o dia quer todas — e resposta encerra a cadência do contato em **todas** elas.

E o texto só vira texto quando o payload é string, pela mesma trava que o D48 pôs no classificador:
objeto viraria `[object Object]` e número viraria `0`. Vir vazio é honesto — a tela diz "pode ter
sido áudio, imagem ou anexo; abra a conversa no aplicativo". Inventar que a pessoa escreveu
`[object Object]` não é.

**O que ela não é:** caixa de entrada com estado. Não há "lida", não há "respondida", não há
atribuição. Inventar estado aqui seria criar colunas sem quem as escreva — o `tem_adapter` do D31
outra vez, e desta vez eu estaria cometendo o defeito no mesmo commit em que o descrevo. Quem
responde é uma pessoa, no aplicativo do canal, e a tela diz isso.

#### O que este D repete

1. **Fato sem consumidor é fato perdido** (D31, D45, D46). Desta vez o fato estava gravado, correto
   e datado — e ilegível.
2. **Conferir o produtor não é conferir o par.** O D48 conferiu quem escreve o texto, que era a
   lição certa naquele momento. Ninguém perguntou quem o lê.
3. **O pior defeito é o que não quebra nada.** Um teste vermelho avisa. Uma resposta que ninguém lê
   parece um dia sem resposta.

---

### D57 — O funil, e a primeira vez que construímos sobre experiência própria

**Contexto.** O pedido era um Kanban: ver leads em prospecção, contatados, quem respondeu, quem não
respondeu, e quem virou oportunidade. Antes de escrever uma linha, chegou a base de conhecimento da
casa — 261 notas sobre os sistemas que o grupo já construiu.

Havia uma nota chamada `Padrão - Kanban e Pipeline`, com o padrão catalogado em **sete projetos
anteriores**, comparativo entre eles, receita recomendada e — o que vale mais — **as armadilhas já
pagas em produção**.

Isto muda a natureza do trabalho. Não é mais "como eu desenharia um Kanban". É "o que já deu errado
sete vezes, e como não repetir".

#### Quatro armadilhas que moldaram o arquivo

**1. Estágio referenciado por nome.** Dois projetos procuravam o estágio por `'Perdeu'` ou por
`ilike`, e quebraram quando o cliente renomeou. Aqui o código só conhece `slug` e `tipo`; `nome` é
rótulo de tela. O teste renomeia um estágio para `'Lead Quente 🔥'` no meio da execução e confere que
o motor continua achando.

**2. Automação desfazendo o trabalho de gente.** Num projeto, a análise de sentimento moveu para
"Perdeu" uma conversa que tinha **acabado de agendar reunião**. A regra que nasceu disso:
**pessoa move de onde quiser; automação nunca tira de `ganho` nem de `perdido`.** Tem teste, e o
teste tenta as duas automações (`motor` e `ia`) antes de confirmar que só `pessoa` desfaz.

**3. Guarda de reativação por contato.** Um projeto travou o próprio ciclo seguinte ao marcar o
contato como reativado para sempre. Por isso `sem_resposta` é do tipo `aberto`, não `perdido`: uma
campanha nova traz a pessoa de volta para prospecção **sem exceção nenhuma na regra**. E quem pediu
para sair não volta, porque `opt_out` é `perdido` — a mesma regra, agora protegendo.

**4. "Gerenciado por IA" só na UI.** A nota registra, em dois projetos, colunas de automação que a
tela mostrava e o backend não implementava. É o `tem_adapter` do D31 com outro nome — e um dos dois
projetos citados chama-se **"Prospecta AI"**, um antecessor de nome igual e propósito diferente.

Por isso `oportunidade` **nasce sem produtor**, e isso está escrito na migration e **na tela**: a
coluna diz, em voz alta, que nenhuma automação move cards para lá ainda. Quando o classificador
existir, a frase sai. Até lá, quem marca uma oportunidade é uma pessoa, e o produto não finge o
contrário.

#### A porta única, levada a sério

A nota recomenda uma RPC `move_deal(deal, stage, source, reason)` como única porta. Aqui ela é
`SECURITY DEFINER` **e** o D54 tira o `UPDATE` de `deals` do papel `authenticated`. Não é
convenção: não existe outro caminho, e o teste confirma que o UPDATE direto devolve 42501.

Por que DEFINER sem ferir o D41: ela não repete o que a política de RLS diz — ela impõe o que a
política **não sabe expressar** (a atividade gravada e a regra de ganho/perdido). E, por ser
DEFINER, confere `pode_operar` na mão, porque o RLS deixou de conferir por ela. A primeira versão
do teste chamou `mover_deal` como `'pessoa'` sem JWT e levou `insufficient_privilege` — provando a
checagem por acidente, o que é a melhor forma de prová-la.

`deal_activities` é append-only pelo mesmo gatilho de `message_events`: a linha do tempo do card é o
que permite auditar um auto-move errado, e foi a **falta** dela que deixou o caso do sentimento
invisível por semanas no projeto anterior.

#### O que o motor escreve, e o que ele não escreve

Cada estágio corresponde a um fato que o motor já produzia:

| Fato | Estágio | Guarda |
|---|---|---|
| inscrito | `em_prospeccao` | cria o card; semeia o funil se não houver |
| mensagem `enviado` (nunca `simulado`) | `contatado` | só de `em_prospeccao` |
| evento `respondido` | `respondeu` | de prospecção, contatado ou sem resposta |
| encerrou por `fim_dos_passos` | `sem_resposta` | só quem ainda não respondeu |
| entrou na supressão | `opt_out` | de qualquer aberto |

Em shadow mode nada se move para `contatado`, e o teste confirma: ninguém foi contatado, então o
funil não pode dizer que foi. É a mesma distinção que a tela da campanha faz desde o D36.

#### O que este D repete, e o que ele acrescenta

Repete o de sempre: coluna sem consumidor é decoração (D31, D46); silêncio é pior que exceção
(D35); a porta única vale se o privilégio a sustentar (D54).

Acrescenta uma coisa nova, e ela é de método: **este é o primeiro arquivo do projeto escrito a
partir de defeitos de outros projetos da casa, e não dos nossos.** Quatro das asserções de
`tests/funil.sql` existem por causa de bugs que este repositório nunca teve. Sai mais barato assim.

---

### D58 — "Não tenho interesse" não é "pare de me mandar"

**Contexto.** O pedido era fechar o laço do funil: resposta positiva encerra a cadência, o contato
sai da fila e vira lead ganho. A base de conhecimento da casa tem o playbook, e ele começa por uma
correção de rumo que custou caro ao projeto anterior:

> IA qualificadora no resgate reperguntava dados e reativava tarde e duplicado → **classificador de
> UMA mensagem** · prompt classificador **RECUSA × NÃO-RECUSA (dúvida = não-recusa)**

A pergunta certa não é *"esta resposta é positiva?"*. É *"esta resposta é uma recusa?"* — e tudo o
que não for recusa vai para uma pessoa. Tentar detectar entusiasmo é o que falhou; detectar recusa
e entregar o resto é o que funcionou.

#### A assimetria é o inverso da do D48

O D48 é sobre opt-out, e lá o erro caro é o **falso positivo**: suprimir é imutável, e suprimir quem
queria comprar apaga o cliente para sempre. A trava ficou apertada.

Aqui é ao contrário:

| erro | custo |
|---|---|
| falso positivo de recusa | um lead bom nunca chega ao consultor. **Caro e silencioso** |
| falso negativo de recusa | alguém sem interesse aparece na coluna Oportunidade e uma pessoa descarta em dois segundos. **Barato e visível** |

Então a trava muda de lado: a barra para chamar algo de recusa é **alta**. `ja tenho plano` fica de
fora de propósito — quem já tem plano e respondeu é exatamente quem quer trocar de operadora.

#### E aí apareceu o defeito que eu não estava procurando

Com as duas listas lado a lado, ficou visível que `opt_out_termos` — do D48 — traz:

```
'nao tenho interesse'   vale sozinho
'sem interesse'         vale sozinho
```

Ou seja: **quem respondia "não tenho interesse, obrigado" era suprimido para sempre**, em todos os
canais, em todas as campanhas futuras, e o CRM recebia `opt_out` dizendo que a pessoa pediu para
sair. Ela não pediu.

Isso contradiz o que o próprio D48 escreveu:

> Termo que nao tem outra leitura possivel numa resposta a prospeccao — "pare", "descadastrar" —
> vale sozinho. **Falso positivo aqui e irreversivel.**

"Não tenho interesse" **tem** outra leitura, e é a mais comum: *não quero esta oferta*. Não é *nunca
mais fale comigo*. É a mesma família de erro que o D48 evitou em "quero sair do meu plano" — só que
escapou nestes dois.

Os dois termos saíram do opt-out e ficaram só na recusa. Quem quer de fato sair continua dizendo
"pare", "descadastrar", "me tira da lista", "não envie mais" — esses não têm segunda leitura.

**É decisão de operação, e é reversível em uma linha:** o vocabulário mora numa tabela exatamente
para isso. O lado conservador (suprimir) protege de reclamação; o lado escolhido protege o lead.
Escolhi o segundo porque a supressão é irreversível e a recusa não — que é o critério que o D48 já
tinha escrito e não tinha aplicado a estes dois.

#### Por que a função foi repetida em vez de fatorada

`privado.eh_recusa` usa o mesmo algoritmo de `privado.pedido_de_saida`: normaliza, procura termo
inteiro, exige contexto nas três palavras seguintes quando o termo é ambíguo. Fatorar as duas numa
função comum seria a refatoração óbvia — e seria errada. **As duas listas têm assimetrias opostas**,
e uma função comum convidaria alguém a "melhorar as duas de uma vez", que é precisamente o que não
pode acontecer. A duplicação está escrita na migration com esse motivo.

#### A ordem dos gatilhos, e a rede embaixo dela

Os gatilhos de `message_events` disparam em ordem alfabética de nome:

```
message_events_encerra_enrollment      invariante 4
message_events_funil                   D57: move para `respondeu`
message_events_opt_out_no_texto        D48: suprime se pediu para sair
message_events_qualifica_resposta      D58: este
```

O `q` não é estético — precisa rodar depois do opt-out. E se alguém mudar a ordem, `mover_deal`
recusa de qualquer forma: quem pediu para sair está em `opt_out`, que é `perdido`, e automação não
tira card de lá (D57). **A checagem explícita é para quem lê; a regra é para quando alguém mexer.**

#### Dois achados de processo

**O advisor pegou o que o suite não pega, pela terceira vez.** `recusa_termos` nasceu sem RLS, e o
`get_advisors` marcou em nível ERROR. O suite não pegou porque eu tinha acabado de pôr a tabela na
lista de isenção do meta-teste — ela é catálogo, não tem `tenant_id`, e isso está certo. Só que a
lista isenta das **duas** perguntas de uma vez, e "catálogo sem tenant" e "tabela sem RLS" não são a
mesma isenção. É a divisão do D19 funcionando exatamente como projetada.

**O primeiro conserto foi o errado.** Quando o meta-teste apontou `recusa_termos`, minha primeira
reação foi isentá-la no teste. Isentar é o que se faz com uma regra que não se aplica; aqui a regra
se aplicava e a tabela é que estava errada. O advisor não deixou passar.

---

### D59 — A credencial é do cliente, não do produto

**26/09.** O pedido foi um submenu de configuração — "plataformas vinculadas", com os maiores CRMs do
mercado e o nosso. O que o pedido carrega é maior do que a tela: **cada licença é um tenant, e cada
tenant traz o CRM que já usa.** Um destino fixo no código seria o produto inteiro apontando para o
CRM de um cliente só.

#### O padrão já existia duas vezes, e o CRM era o vão

Chip do cliente entra por `salvar_credencial_remetente` (D26). Chave de modelo entra por
`salvar_credencial_ia`. As duas são por tenant, com o segredo no Vault e a separação decidida pelo
**catálogo**, dentro da função — a tela manda o que foi preenchido e não conhece provedor nenhum
(D28). CRM não tinha nada disso: existia UM destino, o Pipefy, e ele nem era configurável. Pior: o
`_shared/pipefy.ts` que o D3 declara como única fonte de verdade daquele OAuth **nunca foi escrito**,
então o writeback tinha fila (`outbox`) e não tinha para onde ir.

`crm_provider_catalog` + `crm_connections` são o terceiro uso do mesmo padrão. CRM novo é uma linha de
catálogo e zero mudança de UI.

Oito plataformas, com o esquema de autenticação de cada uma **lido da documentação do provedor**, não
escrito de memória, e a página registrada em `docs_url`: token Bearer de private app no HubSpot,
`x-api-token` mais domínio da empresa no Pipedrive, token na query string na v1 do RD Station CRM,
`User-Key` no Ploomes, `client_credentials` com My Domain no Salesforce, `refresh_token` mais data
center no Zoho. Esquema de auth troca de versão, e campo errado no catálogo vira credencial guardada
com um nome que nenhum adapter vai procurar.

**O Softcare é uma suposição.** `base_url` + `token`, e está escrito como suposição no arquivo: zero
ocorrências no repositório e zero na base de conhecimento da casa. Precisa de confirmação antes de
valer como contrato.

#### Vincular guarda a credencial e nada mais

`tem_adapter` é `false` nas oito linhas, e é verdade, não pendência esquecida. Nenhum adapter de CRM
existe; a `outbox` continua drenando para lugar nenhum. A tela **diz isso, e diz antes da lista** —
quem abre a tela vem vincular, e descobrir depois de colar a credencial que nada chega ao CRM é a
ordem errada.

É o D55 (`campaign_agents`) de novo, por escolha e não por descuido. E é o D54 na outra metade:
`sem_adapter` não se resolve por tela nenhuma, então dizer "ainda não" é diferente de dizer "não dá",
e a tela diz qual dos dois.

#### O teste sem Vault, e o que ele NÃO cobre

O Postgres de teste não tem `supabase_vault`, então nenhuma asserção vê um segredo ser gravado e lido
de volta. O padrão é o do `tests/agentes.sql`: com segredo novo, a função corre inteira e para na
borda com `feature_not_supported` — e **essa parada é a prova de que o destino do segredo é o Vault e
não uma coluna**. Todo o resto (separação de `config`, edição, recusas, permissão, gatilho) roda de
verdade, sobre conexões pré-semeadas com um `credencial_secret_id` falso.

Zoho e Salesforce são os cenários de propósito: são os dois de campos **mistos**. Com um provedor de
campo único, uma função que jogasse `p_campos` inteiro em `config` passaria verde — seria a asserção
que o cenário não consegue violar (D36). E o arquivo declara em voz alta o que não cobre, porque
teste que parece cobrir e não cobre é pior que teste ausente.

#### Os dois achados, e os dois vieram de conferir depois de aplicar

**1. Tabela nova nasce larga.** `get_advisors` não achou nada novo, mas conferir a grade de
privilégio no projeto mostrou que `crm_connections` e `crm_provider_catalog` nasceram com INSERT,
UPDATE e DELETE de tabela inteira para `authenticated`. O D19 tirou o *default privilege* nominal, e
o Supabase continua concedendo em `CREATE TABLE`; **e a estreitada do D54 é nominal, tabela por
tabela**, então tabela criada hoje não herda a de ontem.

O RLS segurava a linha, e é por isso que não houve vazamento entre clientes. Mas é o D54 literal:
política decide quais LINHAS, `GRANT UPDATE` de tabela inteira decide quais COLUNAS. Com a grade
larga, um admin do próprio tenant escrevia `credencial_secret_id` por uma chamada de PostgREST. Isso
não lê segredo nenhum (`segredo_da_conexao_crm` não é de `authenticated`, D44) — faz o worker chamar
o CRM com a credencial de outra conexão, que é a pior forma de errar, porque parece funcionar.

E as vizinhas, que é o que o D54 manda olhar: `ai_credentials` é a irmã exata — ponteiro de Vault,
tela de uma coluna, escrita por função DEFINER — e estava larga desde o D17. Junto foram
`provider_servers` e os três catálogos.

**2. `CREATE OR REPLACE` não faz merge.** A primeira versão dessa segunda migration foi escrita a
partir da cópia do corpo que está no D54, e apagou em silêncio as revogações de `deals` e
`deal_activities` (o "porta única" do D57) e o `SET search_path` da corretiva do D54. Quem pegou foi
`tests/funil.sql`, com uma asserção sobre um assunto que a migration não mencionava.

A lição vale além desta vez: **teste vermelho num arquivo que você não tocou é informação, não
ruído.** E o corpo de uma função se escreve a partir do corpo ATUAL, nunca da migration em que ele
apareceu pela primeira vez.

#### O que isto não resolve

O writeback continua sem destino. `tem_adapter` é falso nas oito, e o primeiro adapter de CRM é uma
decisão em aberto — Pipefy, porque o contrato do D3 e o mapa de fases já existem, ou Softcare, se é
nele que o beta vai rodar. A credencial guardada agora é o que torna esse dia uma mudança de código
só, sem voltar a pedir chave a ninguém.

---

### D60 — Entrar com e-mail e senha, e o link só para definir a senha

**O sintoma.** Mesmo tendo entrado, abrir o endereço do app de novo mostrava "receber link de
acesso". A conferência no projeto explicou sem precisar de hipótese: a última sessão do único
usuário tinha sido renovada em 25/09 às 20:57, e nada depois — o navegador de hoje não carregava
sessão nenhuma para aquele endereço.

A sessão do Supabase mora no `localStorage`, e `localStorage` é **por endereço**. Cada deploy da
Vercel tem um endereço próprio, o preview do PR tem outro, a produção tem outro. Com link por
e-mail, cada endereço novo custava um e-mail novo e uma espera — e parecia defeito de login, porque
"eu já tinha entrado".

**A decisão.** A tela de entrada passa a ser e-mail e senha (`signInWithPassword`). O e-mail fica
para o que ele faz bem: **definir a senha** na primeira vez e trocá-la quando esquecida
(`resetPasswordForEmail` → a pessoa volta pelo link → `updateUser({ password })`).

Isso inverte o que a tela antiga dizia de si ("sem senha para vazar"). A troca é consciente: o
custo do link apareceu no uso, todo dia, e o ganho dele — não existir senha — é pequeno num produto
de operação interna com poucos usuários por cliente.

**Duas armadilhas que o código trata.**

1. **O link de "definir senha" não pode virar acesso sem troca de senha.** Ao voltar do e-mail, o
   Supabase grava a sessão e só então avisa `PASSWORD_RECOVERY` — num `setTimeout`. Se a tela
   dependesse só do aviso, bastaria o React montar depois dele para a pessoa cair no painel,
   logada, sem nunca ver o campo de senha nova. Por isso `app/src/supabase.ts` lê o fragmento da
   URL **antes** de criar o cliente, e o portão segura o painel até a senha ser gravada. O aviso
   continua escutado; ele só deixou de ser a única fonte.
2. **Link expirado não pode voltar em silêncio.** O Supabase devolve o erro no fragmento
   (`error_code=otp_expired`), e a tela antiga mostrava o formulário como se nada tivesse
   acontecido. Agora a tela abre em "definir a senha", com o motivo escrito, e o fragmento sai do
   endereço para o recarregar não repeti-lo.

A regra sem rede está em `app/src/acesso.ts`, com teste em `tests/acesso.test.ts` (11 casos, na
bateria). O caminho "sessão salva → painel direto" foi conferido no navegador com Playwright:
nenhuma chamada a `/auth` e nenhum formulário de senha na tela.

**O que continua valendo do D50.** O link de definir senha usa o mesmo `redirectTo` do link antigo
e a mesma lista de Redirect URLs do painel do Supabase — a tela continua dizendo em voz alta para
onde pediu que o link volte.

**O que isto não resolve.** A sessão continua sendo por endereço: abrir um preview novo pede login
de novo. A diferença é que agora "de novo" é digitar a senha, não esperar e-mail. Usar sempre o
mesmo endereço — o de produção — é o que faz o "já estou logado" valer entre uma visita e outra.

### D61 — SMTP Locaweb como segundo e-mail, pela API e não pelo protocolo

**O pedido.** Usar o SMTP da Locaweb como canal alternativo de envio de e-mail, ao lado do Resend.

**A leitura do D30.** O protocolo SMTP continua sem adapter: precisa de socket, e `adapters/` só
fala `fetch` — é o que faz o mesmo arquivo rodar no Deno e no Node do teste. Mas o "SMTP Locaweb" é
um produto, e o produto tem API REST (`api.smtplw.com.br/v1/messages`, token no cabeçalho
`x-auth-token`, conferida no OpenAPI publicado). É ela que o adapter usa. A linha `smtp` do catálogo
continua lá, sem adapter, e agora diz onde está a alternativa.

**Três diferenças para o Resend, e cada uma virou escolha escrita.**

1. **O assunto vai como está.** A API pede ASCII ou *encoded-word* (RFC 2047), e quase todo
   assunto em português tem acento. `codificarAssunto` (em `adapters/email.ts`, porque é dialeto
   de e-mail e não do provedor) faz `=?UTF-8?B?...?=` em pedaços de até 75 caracteres sem partir
   caractere, e troca quebra de linha por espaço — quebra de linha em cabeçalho é injeção.
2. **O webhook não devolve o id do envio.** O POST responde com um id numérico, mas o webhook
   (formulário, não JSON) traz só destinatário, assunto, código do bounce e o valor do cabeçalho
   `X-Smtplw` da mensagem. Então o `message_id` do motor vai no `X-Smtplw` e é **ele** o
   `providerMessageId`: o evento casa pelo que nós mandamos, dentro do tenant do chip (D38). O id
   da Locaweb não é guardado, porque nada o leria de volta. Evento sem um uuid no `X-Smtplw` é de
   outro sistema que usa a mesma conta, e é descartado.
3. **A Locaweb não recebe e-mail.** A resposta vai para o `Reply-To`. Sem ele apontando para um
   inbound que o motor lê, a pessoa responde para uma caixa que ninguém processa e a cadência segue
   mandando toque — a invariante 4 furada sem erro nenhum. Por isso `responder_para` é
   **obrigatório** na Locaweb (e não no Resend, onde o próprio domínio de envio pode receber). Hoje
   o único inbound que o motor lê é o da Resend; `registrar_resposta_por_numero` casa pelo endereço
   dentro do tenant e do canal, sem filtrar pelo chip, então a resposta a um e-mail que saiu pela
   Locaweb é reconhecida mesmo chegando pelo webhook de uma conta Resend.

**Devolução.** A Locaweb manda o código SMTP estendido (RFC 3463), não "hard"/"soft". Só `5.1.x`
(status de endereço: caixa ou domínio inexistente) conta como permanente. `5.7.x` também é
permanente, mas é política do servidor de destino — reputação, conteúdo — e suprimir o endereço
por isso seria culpar o contato pela conta. O resto é temporário (D49).

**O que se perde.** A API não aceita chave de idempotência. A invariante 1 continua garantida no
banco pela chave `(enrollment_id, step_id)`; o que some é a proteção do Resend para quando o lease
expira com o POST em voo. Pelo mesmo motivo, `201` sem id no corpo conta como envio: marcar um
e-mail enfileirado como falha convidaria o reenvio. E não há evento de entrega, clique ou denúncia
— a Locaweb só avisa bounce e abertura; nada é inventado para preencher.

**O que mudou fora do adapter.** `canal-webhook` lia todo corpo com `req.json()`, e formulário
virava `{}` sem erro: todo bounce da Locaweb responderia 200 e não viraria evento nenhum. Agora
`lerCorpoWebhook` (em `motor/webhooks.ts`, testada) decide pelo `Content-Type`.

**Estado.** Aplicado e publicado em 02/10, nesta ordem: primeiro as três edge functions (v4), cada arquivo do bundle lido de volta do projeto e comparado byte a byte (15, 15 e 14 arquivos), e só então a migration — assim não houve instante em que o catálogo dissesse `tem_adapter = true` para a Locaweb com um worker que não a conhece (D31). O catálogo do projeto foi comparado, linha a linha por digest, com o de um banco montado só com as migrations do repositório: idênticos. O `get_advisors` não acusou nada novo — a migration só insere dados.

**Não conferido contra a conta real.** O formato do `POST` e o do webhook vêm da documentação
pública e de um cliente .NET de terceiros; a primeira conta cadastrada precisa de um envio em
shadow mode desligado para um endereço de teste antes de entrar numa campanha.

### D62 — O e-mail de cada campanha, a conta que se remove sem apagar a história, e a conexão conferida pela tela

**O pedido.** O cliente escolhe, nas configurações, qual provedor de e-mail usar. Pode cadastrar
vários, mas cada campanha usa um. Configurações ganha um submenu **E-mail** com adicionar,
remover e verificar o estado da conexão.

**1. A escolha mora na campanha, e quem a respeita é o roteador.** `campaigns.remetente_email_id`
(FK composta `(tenant_id, id)`, D18). `NULL` é o rodízio de antes — as campanhas existentes
continuam fazendo o que já faziam, porque mudar o comportamento delas em silêncio é pior do que
mantê-lo. `privado.remetentes_da_campanha` é `remetentes_disponiveis` com o filtro da campanha, e
**agendador e despachante passam os dois a perguntar a ela**: escolher a conta no agendador e
deixar `reivindicar_pendentes` rebalancear para outra seria o D40 — os dois discordando sobre o
mesmo fato. O despachante também confere a escolha na mensagem que **já existe** (passo 4): trocar
o provedor na tela vale para o que está na fila, não só para o que vai nascer. É o D37 aplicado à
escolha da pessoa.

Conta escolhida fora do pool **segura** o e-mail da campanha (o passo espera, D31) em vez de sair
por outra. Mandar pelo provedor que ninguém escolheu seria a escolha valendo só enquanto nada dá
errado. `proximo_horario_da_campanha` tem o mesmo filtro: sem ele, a campanha seria acordada pela
quota de OUTRA conta — passada inútil e um "adiado até" mentindo.

Um gatilho (`campaigns_valida_email`, DEFINER porque o operador escolhe e não enxerga
`sender_accounts`) recusa com SQLSTATE 23001 o que o motor não conseguiria cumprir: campanha sem
e-mail (gravar valor que o motor não lê, D55), conta de outro canal, conta removida, e conta de
outro pool — o D4 aqui, legível na hora da escolha, e não como exceção no meio do lote.

**2. Remover é arquivar.** `messages.sender_account_id` é `ON DELETE CASCADE`, e `message_events`
vai junto: apagar uma conta apagava a história de tudo o que ela mandou, e o webhook dela — que
ainda recebe bounce de e-mail de ontem — deixava de resolver. `remover_remetente` grava
`removido_em` e `estado = 'desativado'` (um CHECK impede o par incoerente, senão "devolver ao pool"
ressuscitaria a conta), e recusa — listando quais — quando alguma campanha a escolheu. O ponteiro
do Vault fica: mensagem em voo ainda precisa do segredo, e o pendente o despacho rebalanceia. A
unicidade do identificador virou índice parcial, para o mesmo endereço poder ser cadastrado de novo.

**3. Verificar é do worker.** A tela não tem o segredo e não deve ter. A edge function
`verificar-remetente` lê a conta **com o JWT de quem pediu** (o RLS decide se ele alcança), lê o
segredo com a chave do serviço, chama o `checkHealth` do adapter e grava o resultado
(`registrar_verificacao_remetente`, só `service_role`). A decisão mora em `motor/verificacao.ts`,
com sete testes. A verificação **não tira a conta do pool**: quem tira é o circuito, com envio de
verdade; duas fontes de "esta conta está fora" discordariam.

**Três furos achados no caminho, todos de privilégio.**

- `authenticated` tinha INSERT de tabela inteira em `sender_accounts`: dava para criar conta com
  `credenciais_secret_id` apontando para o segredo de outro cliente — o D59 na quarta tabela de
  credencial. Agora o INSERT é por coluna, sem o ponteiro.
- `authenticated` tinha DELETE em `sender_accounts`, que apagava em cascata mensagens e eventos —
  história append-only. Revogado; remover é a função.
- `provisionar-instancia` lia o servidor só com a chave do serviço: qualquer usuário logado, de
  qualquer cliente, que soubesse um `server_id`, criava instância com o token de administração de
  outro cliente. Agora o servidor é lido primeiro com o JWT do pedido. A function também não
  respondia ao `OPTIONS` do navegador — o app não conseguia chamá-la. `_shared/http.ts` dá CORS e o
  cliente do usuário às duas functions que a tela chama.

**O corpo da grade no projeto não era o do repositório — só nos comentários.** Antes de aplicar,
o corpo de `processar_vencidos`, `reivindicar_pendentes` e `estreitar_escrita_do_cliente` no projeto
foi comparado por md5 com o do banco montado com as migrations. Os dois primeiros bateram; o
terceiro, não: a corretiva do D59 entrou no projeto sem os comentários longos. As instruções são as
mesmas, linha a linha, e o corpo novo é um superconjunto — a diferença não esconde regra nenhuma.

**A tela.** Configurações ▸ **E-mail** lista as contas (sem as removidas), com provedor, pool,
quota, estado e a última verificação ("nunca verificada" é dito como tal — ausência de resultado
não é sucesso), e diz quais campanhas escolheram cada conta. Verificar e remover ficaram na linha
de conta comum, então valem também para WhatsApp e SMS. `/canais/email` redireciona para lá: a
mesma conta em duas telas seriam duas versões do mesmo fato. A tela da campanha ganha "Provedor de
e-mail", só quando a campanha usa e-mail, oferecendo só contas do pool dela.

**Estado.** Aplicado e publicado em 02/10: a migration (60º registro no projeto), a grade conferida
no projeto depois de aplicar (INSERT por coluna sem ponteiro de Vault, sem DELETE,
`remetente_email_id` no UPDATE de `campaigns`), e as duas functions — `verificar-remetente` v1 e
`provisionar-instancia` v5 — lidas de volta e comparadas byte a byte (16/16 e 15/15). O
`get_advisors` só acrescentou `remover_remetente` e `contas_de_email` à família WARN de funções
DEFINER chamáveis pela tela, que checam `pode_administrar`/`pode_operar` em código.

**Não resolvido aqui.** `salvar_credencial_remetente` cria um segredo novo no Vault a cada
salvamento e deixa o anterior órfão. Não vaza nada — ninguém aponta para ele —, mas acumula.

### D63 — A blacklist é do cliente

**O pedido.** Configurações ganha **Blacklist**, onde o cliente define termos, ações e recusas — "todo
tipo de blacklist". E a decisão de operação que reverte o D58: quem responde "não tenho interesse"
também vai para a blacklist.

**O que era.** O vocabulário era do PRODUTO: `opt_out_termos` (D48) e `recusa_termos` (D58), sem
tenant, editáveis só por migration, lidos por dois classificadores com assimetrias opostas. O
comentário de `tests/tenants.sql` já dizia que vocabulário por cliente seria decisão. Chegou.

**O que é.**

- `blacklist_termos`, por tenant, e cada termo tem uma **ação**, porque "casou" não diz o que fazer:
  `suprimir` (a pessoa, em todo canal; CRM ouve `opt_out`), `identidade_invalida` (só o endereço —
  "número errado" —, pelo caminho do D49; CRM ouve `identidade_invalida`) e `recusa` (encerra o ciclo
  sem suprimir; é o D58, que continua disponível para o cliente que o preferir).
- `blacklist_dominios`, por tenant: e-mail de um domínio e dos subdomínios nunca recebe. Mora em
  `esta_suprimido`, a pergunta que roteador, gatilho de `messages` e despacho já fazem — o teste
  bloqueia o domínio DEPOIS de criada a mensagem e confere que ela vira `cancelado` (D39).
- Todo cliente nasce com o padrão (gatilho em `tenants`; os existentes semeados na migration): a
  união das duas listas do produto, com a recusa como `suprimir`, mais três termos de endereço
  errado. `nao quero`, que estava nas duas com contextos diferentes, vira um termo com a união.
- Um classificador só, `regra_da_resposta`, com a ordem `suprimir` > `identidade_invalida` > `recusa`
  e, dentro da ação, o termo mais longo. A assimetria que o D58 guardava em duas funções agora mora
  nessa ordem: uma recusa nunca engole um "pare".
- O termo é normalizado no banco, pela mesma função que normaliza a resposta (D32); a tela manda o
  que a pessoa digitou. "Testar uma resposta" pergunta ao classificador de verdade
  (`testar_blacklist`), em vez de reescrever a regra em TypeScript (D55).

**O que não muda.** Supressão continua imutável. Apagar ou desligar um termo não devolve ninguém —
a tela diz isso antes da lista. E a tela avisa (sem travar) quando alguém cria um termo de uma
palavra só, sem contexto, suprimindo: é o erro que o D48 documentou com "sair".

**Testes que codificavam o mundo de antes.** `tests/funil.sql` usava "não tenho interesse" como a
resposta que para em `respondeu`; no padrão novo ela suprime. O conserto foi o cenário — o cliente do
teste escolhe a ação `recusa` para os dois termos —, não a asserção (a regra do D58). O mesmo em
`tests/qualificacao.sql`, que agora exercita a ação `recusa` trocando-a pela tela.
`tests/blacklist.sql` tem 59 asserções; três sabotagens (sem a cláusula de domínio, sem a
semeadura, sem contexto e sem ordem no classificador) acendem 6, 11 e 2.

**O DROP separado.** No projeto, o MCP do Supabase espera a confirmação de uma pessoa para qualquer
DROP — até `DROP FUNCTION IF EXISTS` de uma função que não existe —, e o chamado inteiro estoura o
tempo sem aplicar nada. Por isso apagar `pedido_de_saida` e `eh_recusa`, que perderam o último leitor,
foi para uma migration própria (`20261002110100_blacklist_aposenta_classificadores`). Sem chamador,
elas não mudam comportamento nenhum enquanto esperam.

**Estado.** A primeira migration está aplicada no projeto (61º registro): 32 termos semeados no
tenant que existe, grade conferida (UPDATE só em `termo, exige_uma_de, acao, nota, ativo`; nada para
anon), e "Não tenho interesse, obrigado" classificado como `suprimir`. O `get_advisors` só
acrescentou `testar_blacklist` à família WARN de DEFINER chamáveis pela tela.

**A segunda, em 05/10.** Aprovada pelo usuário, ela estourou o tempo duas vezes pelo MCP sem aplicar
nada: a confirmação que o DROP espera não chega a uma sessão remota. Disfarçar o DROP para passar pela
trava não é opção — a trava existe para uma pessoa olhar. Quem aplicou foi o usuário, no SQL Editor, com
o `INSERT` em `supabase_migrations.schema_migrations` junto, para o registro existir como o das outras
(66º, versão `20261005150043`). Antes, conferido no projeto que nenhuma função, view, dependência ou job
do `pg_cron` chamava as duas; depois, funções 0 e `get_advisors` sem nada novo.

### D64 — O CRM recebe o fato, e entrega contatos

**O pedido.** Pipefy primeiro: os quatro fatos do contrato (respondeu, pediu para sair, endereço
inválido, cadência concluída) chegam ao CRM, o token renova sozinho, e ao vincular a plataforma os
campos são lidos automaticamente para a pessoa escolher o que usar.

**O que faltava não era o dreno, era o meio.** A `outbox` existia desde o D45 e o dreno desde o
D46; o D59 deu a cada cliente a credencial dele. Faltava dizer o que um fato SIGNIFICA neste CRM:
"respondeu", num cliente, é mover o card para "Em conversa"; noutro, é preencher "Status SDR". Isso
é configuração do cliente, e mora em quatro tabelas:

- `crm_estruturas` — o que a plataforma tem (pipes, fases, campos), lido pela edge function
  `crm-descobrir`, que tem o segredo. A tela oferece escolhas daqui, nunca id digitado à mão. A
  descoberta que falha grava o erro e mantém a estrutura de antes.
- `crm_acoes` — o que cada fato faz, por pipe: **mover de fase** e **preencher campo**, só. Comentar
  e criar card ficaram de fora porque o dreno repete a tentativa inteira quando a anterior falhou no
  meio, e as duas não aguentam repetição. Mover confere a fase antes (já estava? não chama a
  mutação); preencher sobrescreve. Uma fase de destino por fato e pipe, por índice único.
- `crm_vinculos` — qual card é esta pessoa. **Sem vínculo, não há onde escrever**, e o motor não
  procura card pelo telefone: escreveria no card de outra pessoa com o mesmo número. O fato sai da
  fila com o motivo escrito.
- `crm_fontes` — de onde vêm contatos: pipe, fases e qual campo é qual papel. A leitura do card é a
  MESMA da planilha (`adapters/leitura.ts`, extraído de `planilha.ts`): o mesmo celular não pode
  virar WhatsApp por uma porta e sumir pela outra (D32). Opcionalmente a fonte inscreve numa
  campanha, e inscreve **pela prévia** (D35): quem não tem canal da cadência entra como contato, não
  é inscrito, e o resumo da fonte conta quantos. A fonte tem intervalo próprio (mínimo 5 min),
  porque o worker bate a cada minuto e o CRM limita requisição.

**Duas mudanças no dreno.** `reivindicar_writebacks` só pega fato de quem tem plataforma ativa que
sabe escrevê-lo (`tem_adapter`): antes, sem destino, o fato queimaria as oito tentativas e morreria
em `falha` só porque o cliente ainda não vinculou o CRM. E `outbox.resultado` diz o que o dreno FEZ
("card 900 movido para…", "contato sem card vinculado nesta plataforma"). A tela do writeback dizia
"Entregues — o CRM já sabe", que ficou falso no dia: virou "Saíram da fila", com a lista do que cada
um fez.

**O token.** A anti-regra dizia `_shared/pipefy.ts`, que nunca foi escrito. O OAuth mora em
`adapters/pipefy.ts`, porque ali só entra `fetch` e a conversa inteira com o Pipefy é testável sem
rede (D30). Continua um lugar só, e o token continua nunca gravado: nasce por `client_credentials` na
primeira chamada de cada execução, vive na instância, e não serve para outra credencial.

**Ordem de publicação (D31).** Primeiro a migration das tabelas, com `tem_adapter` ainda falso;
depois `motor-worker` v5 e `crm-descobrir` v1, lidos de volta; só então a migration que liga o
adapter. A porta do CRM ganhou arquivos próprios (`motor/porta-crm.ts`, `_shared/banco-crm.ts`) para
as três functions que não falam com CRM não mudarem de bundle.

**Ler de volta sem transcrever.** O bundle do worker tem 25 arquivos e quatro BOMs invisíveis
dentro de uma regex de `csv.ts` — exatamente o tipo de byte que uma transcrição à mão perde (D32).
O payload foi gerado com todo não-ASCII escapado, e a leitura de volta veio de um caminho melhor
que o de antes: a resposta da MCP, grande demais para a conversa, foi salva pelo harness em
arquivo, e `conferir-contra-projeto.py` rodou direto sobre ela. 23/23 idênticos sem que nenhum byte
passasse por cópia.

**Um defeito do próprio suite.** `tests/run.sh` marcava `FALHOU=1` quando `conferir-publicado.py`
falhava e nunca lia a marca: o suite dizia "Tudo verde" logo abaixo de "FALHA motor-worker". Desde
o D51 essa verificação não podia reprovar nada. Agora reprova.

**Testes.** `tests/crm_pipefy.sql` (50 asserções) e `tests/crm.test.ts` (19). Três sabotagens: sem
o filtro de destino no dreno acendem 4; sem a prioridade de mover antes de preencher, 2; inscrevendo
sem a prévia, 4. `tests/plataformas.sql` dizia "nenhuma plataforma declara adapter" — estava certo
ontem; o cenário passou a fotografar "só o Pipefy", e a concordância de verdade é cobrada por
`tests/registro_para_sql.ts` contra `PLATAFORMAS_COM_ADAPTER`.

**Estado.** As duas migrations estão no projeto (62º e 63º registros), com a grade conferida lá
(tela escreve ação e fonte por coluna, nunca vínculo, estrutura nem `ultimo_resultado`; anon nada;
as sete funções novas só de `service_role`) e os corpos com o mesmo md5 do banco de teste. O
`get_advisors` não acrescentou nada. **Falta do lado de quem usa:** vincular o Pipefy pela tela
(client_id e client_secret, que vão para o Vault), ler pipes e campos, configurar as ações e a
fonte. Até lá a fila espera, e a tela diz isso.

**Não resolvido aqui.** Contato que veio de planilha não tem card, e o fato dele sai sem escrever.
Criar card no CRM para quem não tem é possível, mas não é idempotente sem uma chave — fica para
quando houver onde guardá-la. Mudança feita no card depois da primeira leitura não volta ao contato:
a fonte pula cards já vinculados. E o ProfitCare espera a confirmação de que é a linha "Softcare" e
a documentação da API.

### D65 — O backfill começa pelas pessoas e pela supressão

**O bloqueio, e como contorná-lo sem adivinhar.** O projeto legado `gtivnngoeccqbvfjiyne` continua
inacessível: a MCP responde "sem permissão". Mas o schema dele não estava inacessível. O repositório
`sdr-resgate-evolution` é aquele projeto (o `config.toml` diz o id), e as 97 migrations dele,
aplicadas num banco local, reconstroem as 52 tabelas que o inventário da Fase 0 contou. As onze que
o backfill lê viraram `backfill/legado.sql` **geradas do banco reconstruído**, com colunas e tipos
reais. Backfill escrito contra coluna adivinhada é o que quebra no dia, com o dado na mão.

**O recorte.** Esta etapa grava contatos, identidades e supressão, nessa ordem e numa transação.
Ela não leva cadências: inscrever exige uma cadência por campanha antiga (D47), e essa escolha é de
alguém. A prévia conta quantos leads cada campanha ainda tinha em curso, para a decisão ser tomada
com o número na mão.

**As escolhas.**

- **Uma pessoa por telefone normalizado.** A normalização é a do TypeScript (`backfill/normalizar.ts`
  chama `adapters/telefone.ts` e `adapters/email.ts`), e o SQL só lê o resultado (D32).
- **O telefone do legado é de WhatsApp**, porque o legado conversava por ele. É o papel `whatsapp`
  da leitura, a coluna que declara o canal. Vira SMS também só quando é celular (D33).
- **O nono dígito.** WhatsApp antigo guardava número sem o nono dígito, e pela regra de
  `telefone.ts` ele é fixo. Esses números entram como WhatsApp, sem SMS, e a prévia conta quantos
  são e quantos aparecem nas duas formas. Mudar a regra é mudar a normalização de todo o produto,
  e isso é decisão, não detalhe do backfill.
- **Suprimir por três caminhos, todos para o mesmo lado** (D13.4): a lista de bloqueio, o contato
  bloqueado pelo operador (`is_blocked`, que o mapa não cobria) e o lead que o mapa manda suprimir.
- **A supressão não depende de a ingestão dar certo.** Quem o legado bloqueou e não pôde virar
  contato (as identidades já eram de contatos diferentes no cliente) é suprimido pelo endereço, nos
  dois canais do telefone.
- **Nada é fundido.** E-mail que aparece em dois telefones não é ligado a nenhum. Colisão com
  contatos do cliente vira linha em `backfill.recusas`, com o motivo.
- **Os opt-outs do legado não vão para a fila do CRM.** O gatilho do D45 os enfileiraria. São
  decisões que o legado já tinha tomado, e nenhum destes contatos tem card ligado. O relatório
  conta os que não foram.

**A prévia mentia, e o teste pegou.** O texto dizia "nome só preenche". `ingerir_contato` troca o
nome quando o novo vem preenchido; só o vazio não apaga. Corrigido o texto, não a regra: a regra é a
de toda ingestão, e mudar só no backfill seria a segunda regra.

**Testes.** `tests/backfill_fixture.sql` monta o legado em miniatura e prova, antes de normalizar,
que gravar é recusado. A suíte passa então o fixture pelo `normalizar.ts` de verdade, e
`tests/backfill_legado.sql` confere o resto. São 39 asserções. Duas sabotagens: sem a supressão por
endereço dos recusados caem 2, e sem o caminho do contato bloqueado caem 3.

**Para rodar** com o dado real: `backfill/RODAR.md`. Quem tem acesso ao legado exporta, a prévia é
lida, e só então se grava.

**Fica para depois:** campanhas, cadências, enrollments, mensagens e eventos do legado, com a linha do
tempo preservada (MAPA-STATUS). Isso depende de decidir o que fazer com quem ainda estava em
cadência.

### D66 — O agente compõe; uma pessoa decide

**O pedido.** Uma ferramenta 100% autônoma, com agentes configuráveis por instrução,
comportamento, o que é permitido e o que é proibido, e restrições, no molde do SDR Resgate, só
que multicanal.

**Por que não começar pelo autônomo.** `PROPOSTA-CONVERSA.md` mostrou que o agente que manda
sozinho encosta em três garantias. São a invariante 4, o gate do D40 (que cancela a mensagem
pendente em enrollment encerrado por resposta) e a chave `(enrollment_id, step_id)`, e cada uma
foi escrita depois de um defeito real. A opção A entrega a parte cara e incerta, o agente compor
bem, sem tocar em nenhuma delas. Foi o que se construiu.

**O que existe.**

- **`rascunhos`**: uma linha por resposta que o agente leu, com o texto ou com o motivo de não
  haver texto. São sete situações: pronto, recusa, escalar, bloqueado, limite, sem_credencial e
  erro. Uma resposta tem um rascunho (índice único), e só a mais recente de cada pessoa espera
  rascunho.
- **`respostas_para_rascunhar`**: a fila do worker, com tudo o que o agente precisa (instrução,
  conversa nos dois sentidos, variáveis do contato). Ela **exclui quem está suprimido**, a pessoa e
  o endereço, porque rascunho pronto é convite a uma pessoa mandar.
- **`adapters/ia.ts`**: o Claude (Messages API) e a família "chat completions" (OpenAI, DeepSeek,
  OpenRouter, Perplexity, endpoint compatível), só por `fetch` (D30). O Gemini fica sem adapter, e
  `ai_provider_catalog.tem_adapter` diz isso. `tests/registro_para_sql.ts` compara as duas listas,
  que é o D54 no terceiro catálogo.
- **`motor/agente.ts`**: o pedido ao modelo e os **freios em código**. A instrução pede ao modelo; o
  freio confere o que ele devolveu. Barra frase proibida (sem acento e sem caixa), texto acima do
  tamanho máximo e pedido de CPF, senha ou cartão, e reconhece a marca de escalar. Recusa da
  blacklist, limite de trocas e falta de credencial não chamam modelo nenhum.
- **O agente ganhou porta.** `proibido` e `tamanho_maximo` são colunas novas, e `limite_trocas` e
  `escalar_quando`, que existiam sem leitor (PROPOSTA §6), passaram a ser lidos. A credencial se
  escolhe na tela. O UPDATE de `agents` virou por coluna, sem o dono e sem `pronto`, porque o RLS
  segurava a linha enquanto o privilégio soltava a coluna (D54).
- **As telas.** A de Respostas mostra o rascunho embaixo da resposta, com "copiar", ou o porquê de
  não haver. A de Agentes edita o agente do cliente. Três textos que diziam "nada no motor lê
  `campaign_agents`" ficaram falsos no dia e foram reescritos (D58).

**Erro transitório não vira linha.** Um 529 ou uma queda de rede é tentado de novo na passada
seguinte. Só o que não melhora sozinho (chave recusada, modelo inexistente, recusa do modelo) fica
gravado como `erro`, com o motivo.

**Testes.** `tests/rascunhos.sql` (21) e `tests/agente.test.ts` (14). Tirar o filtro de supressão
da fila derruba "suprimida, ela some da fila do agente". Foi escrito e removido um "e conta para o
limite de trocas" que era `true` sozinho, a asserção que o cenário não viola (D36). O limite é
cobrado pelo número de rascunhos anteriores na resposta seguinte.

**Ficou para decidir:** a opção B, desenhada em `PROPOSTA-CONVERSA.md` §8, com recomendação para as
quatro perguntas. A recomendação: autônomo por agente, a resposta paga quota, janela de 24h como
trava, e teto diário por cliente.

### D67 — O assistente pergunta, monta o plano, e não faz nada sozinho

**O pedido.** Um menu inicial com um agente que configura tudo: pergunta por quais canais enviar,
quantas mensagens por dia e o resto, e configura credenciais e acessos pedindo permissão à pessoa.

**Por que roteiro, e não modelo de linguagem.** No primeiro acesso o cliente ainda não tem chave de
IA, e a chave é dele (D59): o produto não tem uma própria para emprestar. Um assistente que precisa
de IA para existir não configura o produto que ainda não tem IA. As perguntas são fixas, cada
resposta vira uma ação concreta, e a lógica inteira (`app/src/assistente.ts`) é pura e testada sem
rede. Uma camada de conversa livre por cima é possível depois que existir chave, mas a decisão do que
fazer continua sendo deste roteiro.

**O que ele pergunta.** Canais (o que nenhum provedor sabe enviar aparece marcado, não some, D54);
para quem (base própria ou lista fria, porque é isso que decide o pool); quantas por dia em cada
canal; oficial ou não oficial no WhatsApp, numa pergunta só para isso (D27); o provedor de cada
canal, ou "usar as que já tenho"; IA; CRM; e a primeira campanha, entre os modelos do mesmo pool com
algum canal em comum (D47).

**O plano.** Cada ação é um cartão que diz o que vai acontecer **antes** do botão que faz. Nada roda
sem "Autorizar", e a escrita sai com o JWT de quem clicou: quem decide se pode é o RLS. O
`impedimento` só avisa antes. O cartão de chave usa a mesma função da tela do canal (`conectarConta`,
que saiu de dentro de `Canal.tsx` para as duas não divergirem sobre o que vai para `config`, D28).
O valor digitado vive no estado do cartão e é apagado assim que a função o recebe. O que o navegador
guarda são as respostas, nunca um valor de campo, e o teste de ponta a ponta no navegador confere
isso: a chave só aparece no corpo de `salvar_credencial_remetente`, nem na linha da conta nem no
`localStorage`.

**O estado é o banco.** "Onde você está" é lido a cada vez: contas, chaves, conexões, campanhas e
contatos. Não há tabela de progresso do assistente, porque uma coluna "configurado" seria um fato sem
quem o produza, e mentiria no dia em que alguém configurasse pela tela (D31). Sem migration.

**Quanto cada conta aguenta.** O assistente propõe um ponto de partida por conta e por dia: 40 para
chip não oficial em lista fria, 80 em base própria, 250 para o oficial, 200 por conta de e-mail e
500 por conta de SMS. **Não é limite de provedor**, que muda com a conta e o tempo. É o número
conservador para começar, editável no cartão. Quando o volume pedido passa do que as contas aguentam,
o plano diz quantas contas faltam em vez de pôr uma conta só no limite. Conta só conta se for do mesmo
pool, porque `privado.remetentes_disponiveis` escolhe por `tipo_permitido` e nada mais.

**O que a sabotagem achou.** Aceitar uma opção indisponível fazia `roteiro` girar para sempre: a
resposta era válida, mas nenhuma pergunta seguinte a lia, e a mesma pergunta voltava. Não era só
hipótese. No dia em que o Instagram ganhar adapter, ele passaria a ser escolhível sem que o assistente
soubesse configurá-lo. Hoje a opção fica indisponível "até o assistente saber", e `roteiro` para
quando a mesma pergunta se repete.

**Acessos de equipe ficam de fora.** Convidar outra pessoa para o cliente exige criar usuário no
Auth, o que só a chave de serviço faz, e ela não passa pela tela. O assistente diz, em cada cartão,
qual papel o passo exige (dono ou admin para conta, chave e CRM; operação para campanha, agente e
importação).

**Testes.** São 20 em `tests/assistente.test.ts`. Cada regra foi sabotada e derrubou pelo menos uma
asserção: pool ignorado, famílias misturadas, opção indisponível aceita, resposta órfã chegando ao
plano, permissão desligada e aviso de capacidade desligado.

### D68 — Toda chave em Configurações; a campanha escolhe a conta

**O pedido.** Chave de API se configura num lugar só: Configurações ▸ Provedores de IA, com quantas
contas de cada provedor o cliente quiser (várias da OpenAI, várias da Anthropic). Na campanha e no
assistente, a pessoa só escolhe: primeiro qual IA, depois qual das contas já conectadas. E o mesmo
vale para toda chave de API.

**Várias contas por provedor já existiam.** `ai_credentials` é única por `(tenant, nome)`, não por
provedor. Faltava a tela mostrar isso: agora ela agrupa as contas por provedor, diz "conectar outra
conta" e liga e desliga cada uma (`ativo`, que já tinha UPDATE por coluna desde o D59).

**A conta mora na campanha, não no agente.** O agente é uma persona que várias campanhas dividem: a
cópia do cliente nasce uma vez por nome em `atribuir_agente`. Escolher a conta no agente a partir de
uma campanha trocaria a conta de todas as outras que usam a mesma persona. Por isso existe
`campaigns.ai_credential_id`, com chave estrangeira composta `(tenant_id, id)` e `ON DELETE SET NULL`
só da coluna. `respostas_para_rascunhar` usa `coalesce(conta da campanha, conta do agente)`. Sem
escolha, vale a do agente, que é o comportamento de antes. O worker não mudou: a função continua
devolvendo `credencial_id`, só escolhido de outro jeito.

**O assistente não pede chave nenhuma.** Os cartões de conectar conta, guardar chave de IA e conectar
CRM saíram. Para IA, a conversa pergunta o provedor e, se houver conta, qual delas; sem conta, o plano
leva a Configurações ▸ Provedores de IA, e a pergunta "qual conta?" surge quando a conta aparece no
banco. Para canal, sem conta o cartão leva à tela do canal; com conta, a escolha é usar. Conectar
mais uma também é na tela do canal, que é onde a chave é digitada. Para CRM, o cartão leva às
Plataformas vinculadas e fica "pronto" quando a conexão existe, lido do banco. "Pôr um agente em cada
canal" atribui os agentes e aponta a conta na CAMPANHA, sem escrever no agente.

**Testes.** `tests/rascunhos.sql` ganhou cinco asserções, e 26 passam. A conta da campanha vale sobre
a do agente, a campanha não aponta conta de outro cliente (23503), apagar a conta solta a campanha,
sem escolha volta a do agente, e o operador escolhe pela tela. Duas sabotagens: sem o `coalesce`
cai uma, e sem a coluna na grade cai outra. `tests/assistente.test.ts` tem 22 testes. Cinco
sabotagens derrubam cada uma pelo menos um: "conectar mais" oferecido com conta existente, conta
desligada escolhível, sem a pergunta de conta, "pronto no banco" não cumprindo a dependência, e o
agente sem esperar a conta. Dois testes antigos ainda citavam o tipo de cartão removido e passavam
de graça; foram reescritos para afirmar o que o plano novo faz.

**Aplicado no projeto.** Os corpos no projeto foram conferidos por md5 antes (iguais aos do D66).
Depois de aplicar, os hashes das duas funções e a grade de `campaigns` batem com o banco de teste.
São 65 registros, e o `get_advisors` não achou nada novo.

**Fica por dizer.** O motivo `sem_credencial` do motor ainda diz "a credencial do agente está
desligada" quando a conta desligada é a da campanha. O texto mora em `motor/agente.ts`, e corrigir
exige republicar o worker. Fica para a próxima vez que ele for publicado por outro motivo.

### D69 — O agente responde sozinho

**A decisão.** Em 05/10 o usuário decidiu a opção B de `PROPOSTA-CONVERSA.md` §8: o agente tem
autonomia para responder. As quatro perguntas do §8 ficaram assim:

- **(a)** A autonomia é por agente (`agents.autonomo`) e vem **ligada**, porque essa é a decisão.
  Desligar devolve o agente ao D66: rascunho para uma pessoa.
- **(b)** A resposta do agente paga quota, como qualquer mensagem (invariante 3).
- **(c)** No WhatsApp e no Instagram, fora da janela de 24h a mensagem não sai. O rascunho volta para
  uma pessoa com o motivo.
- **(d)** Há um teto diário de composições por cliente (`tenants.teto_agente_dia`, 200 por padrão),
  contado na própria `rascunhos`. Passou do teto, a situação é `limite` e o modelo nem é chamado.

**As três travas, uma a uma.**

- **Invariante 4:** continua absoluta. A resposta encerra todas as inscrições da pessoa e a cadência
  não volta a falar com ela. O que passa é a mensagem do agente, que nunca é de cadência.
- **Gate do D40:** ganhou um critério positivo, e só um. Numa inscrição encerrada por `resposta`,
  passa somente a mensagem que tem `rascunho_id` **e** responde à última resposta da pessoa. Mensagem
  de cadência nunca tem `rascunho_id` e segue cancelada. Resposta nova aposenta a mensagem que
  respondia à anterior, e o rascunho dela volta para uma pessoa.
- **Chave `(enrollment_id, step_id)`:** a mensagem do agente não tem passo. `messages.step_id` aceita
  NULL, um CHECK exige passo **ou** rascunho (nunca os dois, nunca nenhum), e a idempotência da
  conversa é `UNIQUE (rascunho_id)`. A chave antiga ficou como estava, porque NULL não colide nela.

**O caminho de envio é o mesmo.** `enfileirar_resposta` cria a mensagem como o agendador cria: o
gatilho de supressão, o do pool, `reservar_envio`, e `simulado` em shadow mode. Antes de criar, ela
devolve a uma pessoa nestes casos:
- a pessoa respondeu de novo;
- está suprimida;
- a campanha está desligada;
- a inscrição foi encerrada por outro motivo que não resposta;
- passou a janela;
- não há conta, ou a conta está fora do pool ou sem quota.

No despacho, `reivindicar_pendentes` confere de novo a supressão, a última resposta e a janela.

**Uma regra que o §8 não tinha: a resposta sai pela conta que conversa.** Trocar de chip no meio da
conversa é outro número escrevendo para a pessoa; no WhatsApp oficial, é escrever fora da sessão. A
conta é a que recebeu a resposta: os dois caminhos do webhook passaram a gravar `chip` no evento.
Na falta dele, vale a conta que mandou a mensagem respondida.

Por isso a mensagem do agente **nunca é rebalanceada** (D37). Com a conta fora do ar, a mensagem
espera, e a janela de 24h decide quando ela deixa de valer.

**"Não mandou" nunca é silêncio.** `rascunhos.envio` diz para onde foi o texto pronto:
- `fila`: virou mensagem;
- `pessoa`: o agente não é autônomo;
- `devolvido`: o motor não mandou, com o motivo em `envio_motivo`.

A tela de Respostas lê o status da mensagem, porque "foi para a fila" não é "saiu":
- na fila, enviada ou simulada;
- devolvida, com o texto para copiar.

**Nome novo, sem DROP.** A fila do worker ganhou três colunas (`autonomo`, `composicoes_hoje`,
`teto`). Mudar o tipo de retorno exige DROP, e o DROP pelo MCP não passa da trava numa sessão remota
(D63). Por isso nasceu `respostas_para_o_agente`, e `respostas_para_rascunhar` ficou sem chamador. A
migration que a apaga vai separada, pelo SQL Editor.

**A ordem no worker.** Os rascunhos rodam depois do despacho. Compor chama modelo e demora, e a
cadência não pode esperar por isso. A resposta do agente sai no despacho da passada seguinte: até 5
minutos, que numa conversa por WhatsApp é natural.

**As telas que afirmavam o contrário.** Agentes, Campanha, Respostas e o assistente diziam "quem manda
é uma pessoa" e "nada sai sozinho". Ficou falso no dia, que é o "reler o que as telas afirmam" do D58.
A tela do agente ganhou "Responde sozinho", com o que impede o envio dito antes do botão. A da
campanha mostra "agente" no lugar do passo.

**Testes.** `tests/agente_responde.sql` tem 33 asserções. A primeira é o teste que o §8 exigia: na
mesma inscrição e na mesma passada, o segundo toque da cadência é cancelado e a mensagem do agente
sai. Cinco sabotagens:

| Sabotagem | Asserções que caem |
|---|---|
| Sem o critério positivo | 4 |
| Critério sem `rascunho_id` (a sabotagem que o §8 pedia) | 5 |
| Rebalancear a mensagem do agente | 1 |
| Sem a janela na saída | 1 |
| Sem a quota | 2 |

`tests/agente.test.ts` ganhou oito testes:
- o pronto vai para a fila no modo da passada, com simulado por padrão;
- o não autônomo não enfileira;
- o barrado e o escalar nunca enfileiram;
- o devolvido é contado;
- a falha de enfileirar é contada e deixa o texto com uma pessoa;
- o teto não chama o modelo;
- o lote soma por cima da fotografia do banco, por cliente.

**O D68 que ficou por dizer.** O motivo `sem_credencial` agora fala da "conta de IA escolhida" e de
"nem a campanha nem o agente". Entrou na mesma republicação do worker.

**Aplicado no projeto, nesta ordem.**

1. A migration entrou primeiro. O v6 continuava funcionando sobre as funções antigas, e o v7 chama as
   novas. Antes de aplicar, conferi por md5 que os cinco corpos regenerados batiam com o projeto (D59).
   Depois, os oito corpos novos ou trocados batem com o banco de teste. São 67 registros.
2. A grade no projeto ficou assim: a tela escreve `agents.autonomo`; não escreve `messages` nem
   `rascunhos`; não chama `enfileirar_resposta`. `anon` não chama a fila. O `get_advisors` não achou
   nada novo.
3. O `motor-worker` v7 entrou depois. Foi lido de volta e comparado sem transcrição: 26/26.

O motor segue em `simulado`. A resposta do agente nasce simulada até alguém ligar o envio real.
