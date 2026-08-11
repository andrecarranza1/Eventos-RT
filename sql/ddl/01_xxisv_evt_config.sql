-- ============================================================================
-- XXISV_EVT_CONFIG
-- Configuração de ambiente/credenciais para a integração de Eventos RT
-- (Oracle EBS -> API REST de Eventos NFe da Compliance Fiscal).
--
-- Um registro por ambiente (HML/PROD/QA), conforme os endpoints publicados
-- no Leiaute_API_REST_Eventos_NFe_V1_2.docx.
-- ============================================================================

CREATE TABLE xxisv.xxisv_evt_config (
  config_id          NUMBER        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  env_code            VARCHAR2(10) NOT NULL,   -- HML, PROD, QA
  endpoint_url         VARCHAR2(500) NOT NULL, -- ex: https://app.compliancefiscal.com.br/api-eventos/v1/integracoes/eventos-nfe
  status_endpoint_url   VARCHAR2(500),         -- TODO: endpoint de consulta de status, ainda não documentado pela Compliance (v1.2)
  mult_org_cd            VARCHAR2(50)  NOT NULL, -- header "cd"
  mult_org_hash            VARCHAR2(500) NOT NULL, -- header "hash"
  wallet_path                VARCHAR2(500),     -- Oracle Wallet usado pelo UTL_HTTP para TLS
  wallet_password              VARCHAR2(200),
  http_timeout_sec               NUMBER DEFAULT 30 NOT NULL,
  poll_interval_sec                NUMBER DEFAULT 5  NOT NULL, -- intervalo entre tentativas de polling (DBMS_LOCK.SLEEP)
  poll_max_wait_sec                  NUMBER DEFAULT 90 NOT NULL, -- janela síncrona máxima de espera dentro do envio
  active_flag                          VARCHAR2(1) DEFAULT 'Y' NOT NULL,
  created_by                             VARCHAR2(100) DEFAULT USER NOT NULL,
  creation_date                            DATE DEFAULT SYSDATE NOT NULL,
  last_updated_by                            VARCHAR2(100) DEFAULT USER NOT NULL,
  last_update_date                             DATE DEFAULT SYSDATE NOT NULL,
  CONSTRAINT xxisv_evt_config_env_uk UNIQUE (env_code),
  CONSTRAINT xxisv_evt_config_act_ck CHECK (active_flag IN ('Y', 'N'))
);

COMMENT ON TABLE xxisv.xxisv_evt_config IS
  'Config/credenciais por ambiente para integração de Eventos RT com a API REST da Compliance Fiscal.';
COMMENT ON COLUMN xxisv.xxisv_evt_config.status_endpoint_url IS
  'TODO: pendente de confirmação. O leiaute v1.2 só documenta o endpoint de envio.';

-- Acesso à tabela deve ficar restrito: ela guarda o "hash" da mult-organização (segredo).
-- Ajustar donos/grantees conforme convenção do ambiente.
REVOKE ALL ON xxisv.xxisv_evt_config FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON xxisv.xxisv_evt_config TO xxisv;
