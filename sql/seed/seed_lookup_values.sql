-- ============================================================================
-- Valores a cadastrar em FND_LOOKUP_VALUES para o package
-- XXISV_EVT_COMPLIANCE_PKG, sob o LOOKUP_TYPE já existente no XXISV:
-- 'XXISV_CSF_MULTORG_SIC' (mesmo usado hoje para WALLET_PATH/WALLET_PASSWORD).
--
-- LOOKUP_CODE esperado por get_config_f (xxisv_evt_compliance_pkg.pkb) —
-- ASSUNÇÃO de nomenclatura, ajustar os LOOKUP_CODE reais se forem outros:
--   AMBIENTE          -> 'HOMOLOGACAO' | 'PRODUCAO' | 'QA'
--                        (define, nesta instância EBS, qual dos 3 endpoints
--                        fixos no package deve ser usado — ver gc_url_* em
--                        xxisv_evt_compliance_pkg.pkb)
--   CD                -> valor do header HTTP "cd" (código da mult-organização)
--   HASH              -> valor do header HTTP "hash"
--   WALLET_PATH       -> já cadastrado (reaproveitado do padrão existente)
--   WALLET_PASSWORD   -> já cadastrado (reaproveitado do padrão existente)
--
-- Preferir cadastrar via a tela padrão do EBS (Application Developer >
-- Application > Lookups, ou System Administrator > Application > Lookups)
-- para manter cache/tradução do FND consistentes. O INSERT abaixo é só
-- referência para ambientes não-interativos (scripts de deploy) — ajustar
-- VIEW_APPLICATION_ID / SECURITY_GROUP_ID conforme a instalação.
-- ============================================================================

INSERT INTO fnd_lookup_values (
  lookup_type, security_group_id, view_application_id, lookup_code,
  language, source_lang, description, meaning, tag,
  enabled_flag, start_date_active, end_date_active,
  creation_date, created_by, last_update_date, last_updated_by, last_update_login
) VALUES (
  'XXISV_CSF_MULTORG_SIC', 0, 0, 'AMBIENTE',
  USERENV('LANG'), USERENV('LANG'), 'Ambiente ativo da API de Eventos da Compliance Fiscal', 'Ambiente', 'HOMOLOGACAO',
  'Y', SYSDATE, NULL,
  SYSDATE, -1, SYSDATE, -1, -1
);

INSERT INTO fnd_lookup_values (
  lookup_type, security_group_id, view_application_id, lookup_code,
  language, source_lang, description, meaning, tag,
  enabled_flag, start_date_active, end_date_active,
  creation_date, created_by, last_update_date, last_updated_by, last_update_login
) VALUES (
  'XXISV_CSF_MULTORG_SIC', 0, 0, 'CD',
  USERENV('LANG'), USERENV('LANG'), 'Codigo da mult-organizacao (header cd) da API de Eventos', 'CD', '<PREENCHER_CD>',
  'Y', SYSDATE, NULL,
  SYSDATE, -1, SYSDATE, -1, -1
);

INSERT INTO fnd_lookup_values (
  lookup_type, security_group_id, view_application_id, lookup_code,
  language, source_lang, description, meaning, tag,
  enabled_flag, start_date_active, end_date_active,
  creation_date, created_by, last_update_date, last_updated_by, last_update_login
) VALUES (
  'XXISV_CSF_MULTORG_SIC', 0, 0, 'HASH',
  USERENV('LANG'), USERENV('LANG'), 'Hash da mult-organizacao (header hash) da API de Eventos', 'HASH', '<PREENCHER_HASH>',
  'Y', SYSDATE, NULL,
  SYSDATE, -1, SYSDATE, -1, -1
);

COMMIT;

-- WALLET_PATH e WALLET_PASSWORD não são recriados aqui — já existem no
-- LOOKUP_TYPE XXISV_CSF_MULTORG_SIC conforme informado.
