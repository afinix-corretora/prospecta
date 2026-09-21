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

---

## Decisões adiadas (não decidir agora)

| Tema | Por que esperar |
|---|---|
| RCS | Exige agente verificado junto a agregador/operadoras. Adapter previsto na interface; implementar quando houver volume que justifique o processo. |
| Volumes-alvo e quotas por remetente | Dados virão do shadow mode. Decidir antes é chute. |
| Telas de operação e relatórios | Reversível. Depende de como o flow se comporta em produção. |
| Construtor visual de flows | Só faz sentido quando o time comercial precisar editar (hoje não precisa, D9). |
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
