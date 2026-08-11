CREATE OR REPLACE PACKAGE xxisv.xxisv_evt_compliance_pkg
AUTHID DEFINER
IS
  /* ==========================================================================
     Integração dos Eventos da Reforma Tributária (RT) entre o Oracle EBS
     (views CLL_F255_EVENT_HEADERS_V / _LINES_V / _TAX_LINES_V) e a API REST
     de Eventos NFe da Compliance Fiscal (Leiaute_API_REST_Eventos_NFe_V1_2).

     Escopo desta versão: os 6 eventos mapeados em EBS_RT_Eventos_Mapping_ISV.xlsx
       110001 - Cancelamento de evento
       112130 - Perecimento/perda/roubo em transporte contratado pelo fornecedor
       112140 - Fornecimento não realizado com pagamento antecipado
       211110 - Apropriação de crédito presumido
       211124 - Perecimento/perda/roubo em transporte contratado pelo adquirente
       211128 - Aceite de débito na apuração por emissão de nota de crédito
       211150 - Crédito para bens/serviços que dependem de atividade do adquirente

     Fluxo:
       1) PROCESS_PENDING_EVENTS_P varre CLL_F255_NOTIFICATIONS
          (EVENT_NAME = 'oracle.apps.cll.event_headers'), envia cada evento novo
          via HTTP para a Compliance Fiscal e, na mesma chamada, aguarda de forma
          limitada (poll_max_wait_sec) por um retorno de processamento.
       2) RETRY_PENDING_EVENTS_P é um job recorrente (DBMS_SCHEDULER) que retoma
          eventos que ficaram em POLLING/TIMEOUT além da janela síncrona inicial.

     Configuração:
       As URLs dos 3 ambientes (Homologação/Produção/QA) ficam fixas como
       constantes no corpo do package (gc_url_*). O ambiente ativo nesta
       instância EBS, as credenciais (cd/hash) e o wallet TLS são lidos de
       FND_LOOKUP_VALUES (LOOKUP_TYPE = 'XXISV_CSF_MULTORG_SIC'), mesmo padrão
       já usado para WALLET_PATH/WALLET_PASSWORD. Ver get_config_f no body e
       docs/ARQUITETURA.md para os LOOKUP_CODE esperados.

     TODO — pendente de confirmação da Compliance Fiscal:
       O leiaute v1.2 documenta apenas o endpoint de ENVIO
       (POST /v1/integracoes/eventos-nfe), processado de forma assíncrona via
       RabbitMQ internamente. Não existe, no leiaute atual, um endpoint de
       CONSULTA de status/protocolo. A função privada poll_event_status_f foi
       implementada contra um placeholder (gc_status_url_*, hoje NULL) —
       precisa ser validada/ajustada assim que a Compliance Fiscal publicar o
       contrato real de consulta (ver docs/ARQUITETURA.md).
     ========================================================================== */

  gc_module_name CONSTANT VARCHAR2(30) := 'XXISV_EVT_COMPLIANCE_PKG';

  -- Códigos de evento suportados nesta fase
  gc_evt_cancelamento     CONSTANT VARCHAR2(6) := '110001';
  gc_evt_perec_fornecedor CONSTANT VARCHAR2(6) := '112130';
  gc_evt_nao_fornecido    CONSTANT VARCHAR2(6) := '112140';
  gc_evt_cred_presumido   CONSTANT VARCHAR2(6) := '211110';
  gc_evt_perec_adquirente CONSTANT VARCHAR2(6) := '211124';
  gc_evt_aceite_debito    CONSTANT VARCHAR2(6) := '211128';
  gc_evt_credito          CONSTANT VARCHAR2(6) := '211150';

  -- Exceções públicas
  ex_config_not_found  EXCEPTION;
  ex_unsupported_event EXCEPTION;
  ex_http_error        EXCEPTION;

  -- --------------------------------------------------------------------------
  -- Job principal: varre notificações pendentes e processa cada evento novo
  -- (envio + espera limitada pelo status), no ambiente configurado via
  -- FND_LOOKUP_VALUES (ver get_config_f no body).
  -- --------------------------------------------------------------------------
  PROCEDURE process_pending_events_p;

  -- --------------------------------------------------------------------------
  -- Job de retomada: eventos que ficaram em POLLING/TIMEOUT/ERROR transitório
  -- além da janela síncrona do envio original.
  -- --------------------------------------------------------------------------
  PROCEDURE retry_pending_events_p;

  -- --------------------------------------------------------------------------
  -- Processa um único EVENT_HEADER_ID (útil para reprocesso manual/testes).
  -- --------------------------------------------------------------------------
  PROCEDURE process_one_event_p (
    p_event_header_id IN NUMBER
  );

END xxisv_evt_compliance_pkg;
/
