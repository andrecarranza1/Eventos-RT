-- ============================================================================
-- Exemplo de carga da XXISV_EVT_CONFIG. NÃO commitar credenciais reais neste
-- arquivo — usar apenas como referência do formato e substituir os valores
-- via processo seguro (ex.: script de deploy que lê de um cofre de segredos).
-- ============================================================================

INSERT INTO xxisv.xxisv_evt_config (
  env_code, endpoint_url, status_endpoint_url,
  mult_org_cd, mult_org_hash,
  wallet_path, wallet_password,
  http_timeout_sec, poll_interval_sec, poll_max_wait_sec, active_flag
) VALUES (
  'HML',
  'https://apphml.compliancefiscal.com.br/api-eventos/v1/integracoes/eventos-nfe',
  NULL, -- TODO: preencher quando a Compliance Fiscal publicar o endpoint de consulta de status
  '<CD_MULT_ORGANIZACAO>',
  '<HASH_MULT_ORGANIZACAO>',
  '/opt/oracle/wallets/compliancefiscal',
  '<WALLET_PASSWORD>',
  30, 5, 90, 'Y'
);

INSERT INTO xxisv.xxisv_evt_config (
  env_code, endpoint_url, status_endpoint_url,
  mult_org_cd, mult_org_hash,
  wallet_path, wallet_password,
  http_timeout_sec, poll_interval_sec, poll_max_wait_sec, active_flag
) VALUES (
  'PROD',
  'https://app.compliancefiscal.com.br/api-eventos/v1/integracoes/eventos-nfe',
  NULL,
  '<CD_MULT_ORGANIZACAO>',
  '<HASH_MULT_ORGANIZACAO>',
  '/opt/oracle/wallets/compliancefiscal',
  '<WALLET_PASSWORD>',
  30, 5, 90, 'Y'
);

COMMIT;
