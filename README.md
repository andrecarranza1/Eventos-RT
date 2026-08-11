# Eventos-RT

Integração dos Eventos da Reforma Tributária entre o Oracle EBS e a API REST
de Eventos NFe da Compliance Fiscal, implementada como package PL/SQL
(`XXISV_EVT_COMPLIANCE_PKG`) rodando dentro do próprio banco do EBS — é o
Oracle que chama a API da Compliance, não o contrário.

Arquitetura completa, mapeamento de campos e pontos em aberto: [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md).

## Estrutura

- `sql/ddl/` — tabelas de apoio (controle, log HTTP) e grants
- `sql/acl/` — ACL de rede para chamadas HTTPS de saída
- `sql/packages/` — package `XXISV_EVT_COMPLIANCE_PKG` (spec + body)
- `sql/jobs/` — jobs `DBMS_SCHEDULER` de envio e retry
- `sql/seed/` — valores a cadastrar em `FND_LOOKUP_VALUES` (ambiente/credenciais)
- `docs/` — documentos de origem (Oracle e Compliance) + arquitetura

Endpoint, ambiente ativo e credenciais (`cd`/`hash`/wallet) vêm de
`FND_LOOKUP_VALUES` (`LOOKUP_TYPE = XXISV_CSF_MULTORG_SIC`) — sem tabela de
configuração própria. Detalhes em [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md).
