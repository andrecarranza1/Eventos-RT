# Arquitetura — Eventos-RT (Oracle EBS ↔ Compliance Fiscal)

Integração dos **Eventos da Reforma Tributária** entre o Oracle EBS (solução
CLL_F407 / views `CLL_F255_*`) e a API REST de Eventos NFe da Compliance
Fiscal (`Leiaute_API_REST_Eventos_NFe_V1_2.docx`).

Toda a integração é feita **de dentro do banco Oracle EBS**, por um package
PL/SQL no schema `XXISV`. O EBS é quem inicia as chamadas HTTP para a API da
Compliance — não existe (nem existirá) um endpoint exposto pelo EBS para a
Compliance chamar de volta.

## Fluxo

```
1. Usuário/concurrent da Solução de Eventos (EBS)
   grava em CLL_F255_NOTIFICATIONS
   (EVENT_NAME = 'oracle.apps.cll.event_headers', PARAMETER_VALUE1 = EVENT_HEADER_ID)
        │
        ▼
2. XXISV_EVT_SEND_JOB (DBMS_SCHEDULER, a cada 5 min)
   -> XXISV_EVT_COMPLIANCE_PKG.PROCESS_PENDING_EVENTS_P
        │  lê CLL_F255_EVENT_HEADERS_V / _LINES_V / _TAX_LINES_V
        │  chama CLL_F255_RT_EVENTS_PUB.return_status_p (status = IN PROCESS)
        │  monta o JSON do leiaute Compliance e faz POST via UTL_HTTP
        ▼
3. API Compliance (POST /v1/integracoes/eventos-nfe)
   responde HTTP 202 de forma síncrona (só confirma publicação no RabbitMQ,
   não confirma persistência nem aprovação da SEFAZ)
        │
        ▼
4. Mesma chamada de envio aguarda de forma limitada (poll_max_wait_sec,
   padrão 90s) tentando obter o status final via um endpoint de consulta
   -- TODO: ainda não documentado pela Compliance, ver "Pontos em aberto".
        │
   ┌────┴─────┐
   │resolvido │ não resolvido dentro da janela
   ▼          ▼
CLL_F255_RT_  fica em TIMEOUT/POLLING;
EVENTS_PUB.   XXISV_EVT_RETRY_JOB (a cada 10 min)
return_status_p  -> RETRY_PENDING_EVENTS_P tenta de novo
(APPROVED/CANCELLED/ERROR + protocolo)
```

## Escopo desta versão

Os 6 eventos mapeados em `docs/EBS_RT_Eventos_Mapping_ISV.xlsx`, que
correspondem aos grupos de detalhe P2/P5/P6/P8/P10/P13 do leiaute Compliance:

| Código | Descrição | Sheet Oracle | Grupo Compliance |
|---|---|---|---|
| 110001 | Cancelamento de evento | IN OUT - 110001 | P2 |
| 112130 | Perecimento/perda/roubo — transporte contratado pelo fornecedor (saída) | OUT - 112130 | P5 |
| 211124 | Perecimento/perda/roubo — transporte contratado pelo adquirente (entrada) | IN - 211124 | P5 |
| 112140 | Fornecimento não realizado com pagamento antecipado | OUT 112140 | P6 |
| 211110 | Apropriação de crédito presumido | IN - 211110 | P8 |
| 211128 | Aceite de débito na apuração por nota de crédito | IN - 211128 | P10 |
| 211150 | Crédito para bens/serviços dependentes de atividade do adquirente | IN - 211150 | P13 |

Os demais 24 eventos da matriz da Compliance (`docs/Leiaute_API_REST_Eventos_NFe_V1_2.docx`,
seção "Matriz de eventos suportados") não têm mapeamento Oracle e ficam fora
desta primeira entrega.

## Estrutura do repositório

```
sql/
  ddl/       tabelas de apoio (controle, log HTTP) + grants
  acl/       ACL de rede (DBMS_NETWORK_ACL_ADMIN) para saída HTTPS
  packages/  XXISV_EVT_COMPLIANCE_PKG (spec + body)
  jobs/      DBMS_SCHEDULER (envio + retry)
  seed/      valores a cadastrar em FND_LOOKUP_VALUES (sem segredos reais)
docs/        documentos de origem (Oracle e Compliance) + esta arquitetura
```

### Configuração — `FND_LOOKUP_VALUES`

Em vez de uma tabela de configuração própria, o package lê endpoint, ambiente
e credenciais de `FND_LOOKUP_VALUES` (`LOOKUP_TYPE = 'XXISV_CSF_MULTORG_SIC'`),
o mesmo já usado no XXISV para `WALLET_PATH`/`WALLET_PASSWORD` — reduz o setup
a cadastrar linhas na tela padrão de Lookups em vez de mais uma tabela.
`LOOKUP_CODE` esperados por `get_config_f` (ver `sql/seed/seed_lookup_values.sql`):

| LOOKUP_CODE | Uso |
|---|---|
| `AMBIENTE` | `HOMOLOGACAO` / `PRODUCAO` / `QA` — define qual dos 3 endpoints fixos no package (`gc_url_*`) esta instância EBS usa |
| `CD` | header HTTP `cd` (código da mult-organização) |
| `HASH` | header HTTP `hash` |
| `WALLET_PATH` | já cadastrado — reaproveitado |
| `WALLET_PASSWORD` | já cadastrado — reaproveitado |

As URLs de envio (e, quando existir, de consulta de status) ficam fixas como
constantes no corpo do package (`gc_url_hml/prod/qa`, `gc_status_url_*`) — não
há mais uma tabela por ambiente para isso, conforme pedido. Timeouts e
intervalos de polling (`gc_http_timeout_sec`, `gc_poll_interval_sec`,
`gc_poll_max_wait_sec`) também são constantes no package.

**ASSUNÇÃO:** os nomes de `LOOKUP_CODE` acima seguem a mesma convenção do
exemplo fornecido (`WALLET_PATH`, `WALLET_PASSWORD`); ajustar `gc_lk_cd`,
`gc_lk_hash`, `gc_lk_ambiente` em `xxisv_evt_compliance_pkg.pkb` se os códigos
já cadastrados forem diferentes.

### Tabelas de apoio (schema XXISV)

- **XXISV_EVT_CONTROL** — 1 linha por `EVENT_HEADER_ID` processado: status
  local, protocolo, erros, tentativas. É a fonte da verdade para o job de
  retry e para auditoria — as tabelas nativas `CLL_F255_*` não são alteradas.
- **XXISV_EVT_HTTP_LOG** — auditoria de toda chamada HTTP (request/response),
  necessária para troubleshooting e como evidência de homologação.

### Package `XXISV_EVT_COMPLIANCE_PKG`

- `PROCESS_PENDING_EVENTS_P` — varre notificações novas, envia e aguarda o
  status dentro da mesma chamada (ver "Como funciona a espera pelo status"
  abaixo). Sem parâmetros — o ambiente vem da lookup `AMBIENTE`.
- `RETRY_PENDING_EVENTS_P` — retoma eventos que não resolveram na janela
  síncrona. Sem parâmetros.
- `PROCESS_ONE_EVENT_P(p_event_header_id)` — reprocesso manual de um evento
  específico (testes/homologação).

## Como funciona a espera pelo status

Foi pedido que o próprio envio já tentasse capturar o status processado, sem
depender só de um job separado. Como a API da Compliance é **assíncrona por
desenho** (o `POST` devolve HTTP 202 confirmando apenas a publicação no
RabbitMQ — "não confirma persistência Oracle", com filas de retry de até
300s antes da DLQ), não é possível "segurar" a mesma conexão HTTP até a
aprovação da SEFAZ. A solução implementada:

1. O `POST` é enviado e `CLL_F255_RT_EVENTS_PUB.return_status_p` marca
   `IN_PROCESS` no EBS imediatamente.
2. A mesma rotina de envio entra em um loop limitado
   (`DBMS_LOCK.SLEEP(poll_interval_sec)`, padrão 5s, por até
   `poll_max_wait_sec`, padrão 90s) tentando consultar o status.
3. Se resolver dentro da janela, `return_status_p` já é chamado com o status
   final (APPROVED/CANCELLED/ERROR) na mesma execução.
4. Se não resolver, o evento fica marcado `TIMEOUT` em `XXISV_EVT_CONTROL` e o
   job `XXISV_EVT_RETRY_JOB` continua tentando periodicamente, sem travar a
   sessão do job de envio.

## Pontos em aberto (validar antes de produção)

1. **Endpoint de consulta de status — bloqueante.** O leiaute v1.2 só
   documenta o `POST` de envio. `poll_event_status_f` está implementada
   contra `gc_status_url_*` (hoje `NULL`/placeholder no package) com
   um contrato de resposta assumido:
   ```json
   { "status": "APPROVED|CANCELLED|ERROR|IN_PROCESS",
     "protocolo": "...", "protocoloCancelamento": "...",
     "codigoErro": "...", "mensagemErro": "..." }
   ```
   Sem esse endpoint confirmado pela Compliance, `XXISV_EVT_SEND_JOB` envia o
   evento e marca `IN_PROCESS`, mas nunca vai conseguir avançar sozinho para
   `APPROVED/CANCELLED/ERROR` — os eventos ficam represados em `TIMEOUT`.
2. **Distinção entre `vIbs/vCbs` e `vIbsEstornado/vCbsEstornado` (eventos
   112130/211124).** `EBS_RT_Eventos_Mapping_ISV.xlsx` mapeia os dois pares de
   campos para a mesma coluna `CLL_F255_EVENT_TAX_LINES_V.TAX_AMOUNT`,
   filtrando apenas por `TAX_NAME`, sem uma coluna que diferencie "imposto na
   nota" de "crédito a estornar". `build_dados_perecimento_f` hoje replica o
   mesmo valor nos dois campos — **não habilitar 112130/211124 em produção**
   sem validar isso com o time LAD/Oracle (KB739238).
3. **Vínculo item↔imposto em `CLL_F255_EVENT_TAX_LINES_V`.** Assumido como
   `FD_LINE_NUMBER` (mesma coluna de `CLL_F255_EVENT_LINES_V`), por analogia —
   não confirmado em nenhum dos 3 documentos recebidos.
4. **`vlBaseCalc` (211110) por imposto.** A planilha mapeia um único
   `TAX_BASE` sem distinguir IBS/CBS; assume-se a base do IBS com fallback
   para CBS.
5. **`codCredPresIbs`/`codCredPresCbs` (211110).** A planilha só tem uma
   coluna `COD_CRED_PRES` (sem split por imposto); assume-se que o mesmo
   código de classificação se aplica a ambos.
6. **Estrutura de `CLL_F255_NOTIFICATIONS`.** Só as colunas `EVENT_NAME` e
   `PARAMETER_VALUE1` são citadas na Cartilha; o cursor `c_pending_notifications`
   assume que essas colunas existem tal como documentadas — validar a DDL real
   da view/tabela (KB363191).
7. **Valores de retorno de `CLL_F255_RT_EVENTS_PUB.return_status_p`.** A
   Cartilha não documenta os valores possíveis de `x_return_status`; o package
   assume a convenção EBS padrão (`'S'` = sucesso).
8. **Modelo do documento (`modelo`).** Não há coluna própria mapeada; é
   derivado das posições 21-22 da chave de acesso (`FD_KEY`), com fallback
   `'55'`.
9. **`LOOKUP_CODE` de CD/HASH/AMBIENTE em `FND_LOOKUP_VALUES`.** Nomeados por
   convenção (`CD`, `HASH`, `AMBIENTE`), a partir do padrão já usado para
   `WALLET_PATH`/`WALLET_PASSWORD` — confirmar se os códigos reais já
   cadastrados no `LOOKUP_TYPE XXISV_CSF_MULTORG_SIC` são esses mesmos.

## Pré-requisitos de infraestrutura

- Deploy, nesta ordem: `sql/ddl/01_xxisv_evt_control.sql`,
  `sql/ddl/02_xxisv_evt_http_log.sql`, `sql/ddl/03_grants.sql`,
  `sql/acl/01_setup_network_acl.sql`, `sql/packages/*.pks` depois `*.pkb`,
  cadastro dos `LOOKUP_CODE` de `sql/seed/seed_lookup_values.sql` (com `CD`/
  `HASH` reais, preferencialmente pela tela de Lookups do EBS), e por fim
  `sql/jobs/setup_scheduler_jobs.sql`.
- Oracle Wallet configurado para TLS de saída se os certificados dos hosts
  `*.compliancefiscal.com.br` não estiverem na cadeia de confiança padrão do
  banco (caminho/senha lidos de `WALLET_PATH`/`WALLET_PASSWORD` na mesma
  lookup).
- Usuário de integração `XXISV` com os grants de `sql/ddl/03_grants.sql` —
  manter o princípio de menor privilégio (somente SELECT nas views e EXECUTE
  no `CLL_F255_RT_EVENTS_PUB`, sem DML nas tabelas nativas da Localização).
- Jobs `XXISV_EVT_SEND_JOB` / `XXISV_EVT_RETRY_JOB` ficam `enabled => FALSE`
  por padrão — habilitar só após validar os pontos em aberto acima e rodar ao
  menos um ciclo completo em homologação (ver roteiro de cenários na Cartilha,
  páginas 10-22).

## Referências

- `docs/EBS_RT_Eventos_Mapping_ISV.xlsx` — mapeamento de campos Oracle EBS.
- `docs/Leiaute_API_REST_Eventos_NFe_V1_2.docx` — leiaute da API da Compliance.
- `docs/Cartilha EBS - Eventos - NF Deb Cred.pdf` — cartilha de homologação
  Oracle (fluxo de status, cenários de teste, API `CLL_F255_RT_EVENTS_PUB`).
- CMOS: *LAD Add-on Localizations - R12 ISV Integration Solution* [KB363191].
- CMOS: *LAD Add-on Localizations - Brazil - R12* [KB739238].
