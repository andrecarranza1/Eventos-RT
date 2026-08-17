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
-- UTL_HTTP.SET_PROXY no package (ver g_http_proxy em xxisv_csf_evt_compliance_pkg.pkb)
-- e liberar também o privilégio 'http_proxy' acima (já incluso).

-- TLS: se os certificados dos hosts da Compliance Fiscal não estiverem na
-- cadeia de confiança padrão do banco, é necessário criar/alimentar um Oracle
-- Wallet (orapki) com a CA correspondente e cadastrar o caminho/senha nos
-- LOOKUP_CODE WALLET_PATH/WALLET_PASSWORD (FND_LOOKUP_VALUES, LOOKUP_TYPE
-- XXISV_CSF_MULTORG_SIC — ver sql/seed/seed_lookup_values.sql). UTL_HTTP.SET_WALLET
-- é chamado pelo package antes de cada requisição HTTPS.
--
-- Passo a passo (executar no servidor de banco, como usuário OS "oracle" ou
-- equivalente com permissão de escrita no diretório do wallet):
--
-- 1) Obter o certificado da CA que assina os hosts da Compliance Fiscal.
--    Preferir pedir formalmente o certificado (CA raiz/intermediária, .pem
--    ou .cer) ao time da Compliance Soluções Fiscais — evita depender de
--    extração manual e garante que é a cadeia correta.
--    Alternativa/validação rápida: extrair diretamente do host via openssl
--    (ajustar o host para o ambiente desejado — apphml/app/qa):
--      openssl s_client -connect app.compliancefiscal.com.br:443 -showcerts \
--        </dev/null 2>/dev/null \
--        | openssl x509 -outform PEM > /tmp/compliancefiscal_ca.pem
--    (com -showcerts é possível ver toda a cadeia; se o servidor apresentar
--    intermediária + raiz, considerar importar ambas no wallet).
--
-- 2) Criar o wallet (ajustar o caminho conforme o padrão de filesystem da
--    instalação; não usar -auto_login, pois o package informa a senha
--    explicitamente via WALLET_PASSWORD em cada UTL_HTTP.SET_WALLET):
--      orapki wallet create -wallet /u01/app/oracle/wallets/xxisv_csf -pwd 'SENHA_FORTE_AQUI'
--
-- 3) Importar a CA obtida no passo 1 como certificado confiável:
--      orapki wallet add -wallet /u01/app/oracle/wallets/xxisv_csf \
--        -trusted_cert -cert /tmp/compliancefiscal_ca.pem -pwd 'SENHA_FORTE_AQUI'
--
-- 4) Conferir o conteúdo do wallet:
--      orapki wallet display -wallet /u01/app/oracle/wallets/xxisv_csf -pwd 'SENHA_FORTE_AQUI'
--
-- 5) Restringir permissões do diretório/arquivos do wallet ao usuário OS do
--    banco (ex.: chmod 700 no diretório, owner oracle:oinstall) — o wallet
--    guarda a CA confiável, mas ainda assim não deve ficar acessível a
--    outros usuários do sistema operacional.
--
-- 6) Cadastrar em FND_LOOKUP_VALUES (LOOKUP_TYPE XXISV_CSF_MULTORG_SIC):
--      WALLET_PATH     -> file:/u01/app/oracle/wallets/xxisv_csf   (prefixo "file:" obrigatório)
--      WALLET_PASSWORD -> a mesma senha usada nos passos 2/3
--    (ver sql/seed/seed_lookup_values.sql).

-- Validação:
-- SELECT host, lower_port, upper_port, ace.* FROM dba_network_acls a, dba_network_acl_privileges p
-- WHERE a.acl = p.acl AND p.principal = 'XXISV';
