-- ============================================================================
-- XXISV_EVT_CONTROL
-- Tabela de controle/rastreio dos eventos de Reforma Tributária processados
-- por este package. A Oracle não deve ter suas tabelas nativas (CLL_F255_*)
-- alteradas, então mantemos aqui o estado local do envio/retorno de cada
-- EVENT_HEADER_ID capturado em CLL_F255_NOTIFICATIONS.
-- ============================================================================

CREATE TABLE xxisv.xxisv_evt_control (
  control_id             NUMBER        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_header_id          NUMBER NOT NULL,          -- CLL_F255_EVENT_HEADERS_V.EVENT_HEADER_ID
  notification_id            NUMBER,                 -- CLL_F255_NOTIFICATIONS.NOTIFICATION_ID (se existir PK com esse nome; validar)
  fd_key                       VARCHAR2(44),          -- chave de acesso da NF-e
  event_code                     VARCHAR2(10),        -- código do evento (110001, 112130, ...)
  taxpayer_id                      VARCHAR2(14),      -- CNPJ do autor do evento
  local_status                       VARCHAR2(20) DEFAULT 'PENDING' NOT NULL,
    -- PENDING     -> capturado da notificação, ainda não enviado
    -- SENT        -> POST feito com sucesso (HTTP 202), aguardando confirmação
    -- IN_PROCESS  -> EBS já atualizado com status IN_PROCESS
    -- POLLING     -> dentro da janela de espera, consultando status final
    -- APPROVED / CANCELLED / ERROR -> status finais devolvidos ao EBS
    -- TIMEOUT     -> não resolveu dentro da janela síncrona; aguardando job de retry
  compliance_batch_ref                 VARCHAR2(100), -- "protocolo" de lote do 202 síncrono (ack de recebimento)
  event_protocol                         VARCHAR2(20), -- protocolo final da SEFAZ, quando obtido
  cancel_event_code                        VARCHAR2(10),
  cancel_protocol                            VARCHAR2(20),
  error_code                                   VARCHAR2(20),
  error_message                                  VARCHAR2(4000),
  attempt_count                                    NUMBER DEFAULT 0 NOT NULL,
  first_sent_date                                    DATE,
  last_attempt_date                                    DATE,
  resolved_date                                          DATE,
  created_by                                               VARCHAR2(100) DEFAULT USER NOT NULL,
  creation_date                                              DATE DEFAULT SYSDATE NOT NULL,
  last_updated_by                                              VARCHAR2(100) DEFAULT USER NOT NULL,
  last_update_date                                               DATE DEFAULT SYSDATE NOT NULL,
  CONSTRAINT xxisv_evt_control_hdr_uk UNIQUE (event_header_id),
  CONSTRAINT xxisv_evt_control_st_ck CHECK (local_status IN (
    'PENDING', 'SENT', 'IN_PROCESS', 'POLLING',
    'APPROVED', 'CANCELLED', 'ERROR', 'TIMEOUT'
  ))
);

CREATE INDEX xxisv.xxisv_evt_control_st_ix ON xxisv.xxisv_evt_control (local_status);

COMMENT ON TABLE xxisv.xxisv_evt_control IS
  'Controle local de envio/retorno dos Eventos RT integrados com a Compliance Fiscal (1 linha por EVENT_HEADER_ID).';
