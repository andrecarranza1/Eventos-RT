-- ============================================================================
-- Grants necessários para o schema XXISV executar o package
-- XXISV_EVT_COMPLIANCE_PKG. Ajustar owners conforme a instalação real do
-- EBS (views CLL_F255_* e o package CLL_F255_RT_EVENTS_PUB normalmente
-- pertencem ao schema da Localização Brasil, ex.: JL_BR ou CLL, validar).
-- ============================================================================

-- Leitura das views de Eventos e da fila de notificações
GRANT SELECT ON cll_f255_event_headers_v   TO xxisv;
GRANT SELECT ON cll_f255_event_lines_v     TO xxisv;
GRANT SELECT ON cll_f255_event_tax_lines_v TO xxisv;
GRANT SELECT ON cll_f255_notifications     TO xxisv;

-- Escrita do status de retorno no EBS
GRANT EXECUTE ON cll_f255_rt_events_pub TO xxisv;

-- Leitura da configuração (cd/hash/wallet/ambiente) em FND_LOOKUP_VALUES,
-- LOOKUP_TYPE = 'XXISV_CSF_MULTORG_SIC'. Normalmente já acessível via
-- synonym público (APPS.FND_LOOKUP_VALUES); validar se XXISV precisa de
-- grant explícito nesta instalação.
-- GRANT SELECT ON apps.fnd_lookup_values TO xxisv;

-- UTL_HTTP / rede (além do ACL em sql/acl/01_setup_network_acl.sql)
GRANT EXECUTE ON UTL_HTTP TO xxisv;

-- DBMS_SCHEDULER (se os jobs forem criados por outro usuário que não XXISV)
GRANT CREATE JOB TO xxisv;
