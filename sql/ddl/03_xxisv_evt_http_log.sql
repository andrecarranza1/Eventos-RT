-- ============================================================================
-- XXISV_EVT_HTTP_LOG
-- Log de auditoria de todas as chamadas HTTP feitas via UTL_HTTP para a API
-- da Compliance Fiscal (envio e, quando aplicável, consulta de status).
-- Essencial para troubleshooting e para as evidências exigidas na homologação.
-- ============================================================================

CREATE TABLE xxisv.xxisv_evt_http_log (
  log_id            NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_header_id     NUMBER,
  call_type             VARCHAR2(20) NOT NULL,  -- SEND | POLL
  request_url             VARCHAR2(500),
  request_body               CLOB,
  http_status_code             NUMBER,
  response_body                  CLOB,
  error_message                     VARCHAR2(4000),
  call_date                           DATE DEFAULT SYSDATE NOT NULL,
  CONSTRAINT xxisv_evt_http_log_ty_ck CHECK (call_type IN ('SEND', 'POLL'))
);

CREATE INDEX xxisv.xxisv_evt_http_log_hdr_ix ON xxisv.xxisv_evt_http_log (event_header_id);

COMMENT ON TABLE xxisv.xxisv_evt_http_log IS
  'Auditoria das chamadas HTTP (UTL_HTTP) do package XXISV_EVT_COMPLIANCE_PKG para a API da Compliance Fiscal.';

-- Retenção: considerar purge/particionamento por call_date se o volume justificar.
