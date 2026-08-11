-- ============================================================================
-- ACL de rede para permitir que o schema XXISV faça chamadas HTTPS de saída
-- (UTL_HTTP) para os hosts da API de Eventos da Compliance Fiscal.
--
-- Executar como SYS ou usuário com privilégio EXECUTE em DBMS_NETWORK_ACL_ADMIN.
-- Ajustar os hosts conforme os ambientes realmente utilizados
-- (ver Leiaute_API_REST_Eventos_NFe_V1_2.docx, tabela de endpoints).
-- ============================================================================

BEGIN
  FOR host_rec IN (
    SELECT 'apphml.compliancefiscal.com.br' AS host FROM dual UNION ALL
    SELECT 'app.compliancefiscal.com.br'    AS host FROM dual UNION ALL
    SELECT 'qa.compliancefiscal.com.br'     AS host FROM dual
  ) LOOP
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
      host       => host_rec.host,
      lower_port => 443,
      upper_port => 443,
      ace        => xs$ace_type(
                      privilege_list => xs$name_list('http', 'http_proxy'),
                      principal_name  => 'XXISV',
                      principal_type  => xs_acl.ptype_db)
    );
  END LOOP;
END;
/

-- Se a rede corporativa exigir proxy HTTP para saída à internet, configurar
-- UTL_HTTP.SET_PROXY no package (ver g_http_proxy em xxisv_evt_compliance_pkg.pkb)
-- e liberar também o privilégio 'http_proxy' acima (já incluso).

-- TLS: se os certificados dos hosts da Compliance Fiscal não estiverem na
-- cadeia de confiança padrão do banco, é necessário criar/alimentar um Oracle
-- Wallet (orapki) com a CA correspondente e apontar XXISV_EVT_CONFIG.WALLET_PATH
-- / WALLET_PASSWORD para ele. UTL_HTTP.SET_WALLET é chamado pelo package antes
-- de cada requisição HTTPS.

-- Validação:
-- SELECT host, lower_port, upper_port, ace.* FROM dba_network_acls a, dba_network_acl_privileges p
-- WHERE a.acl = p.acl AND p.principal = 'XXISV';
