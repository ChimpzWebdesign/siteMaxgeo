# ERP SaaS Enterprise Blueprint (Multi-tenant, Dark Mode, Cloud-ready)

## 1) Arquitetura completa do sistema

### 1.1 Princípios arquiteturais
- **Tenant isolation by design**: cada requisição carrega contexto de tenant obrigatório (`tenant_id`, `tenant_slug`, `schema_name`) validado em middleware de borda.
- **Backend e frontend desacoplados**: Next.js (BFF + UI) consumindo API NestJS versionada (`/v1`).
- **Aplicação stateless**: sessões curtas com JWT assinado + refresh token rotativo e revogável no Redis/PostgreSQL.
- **Escala horizontal**: pods sem afinidade; estado em PostgreSQL, Redis, object storage e fila.
- **Domain-driven modular monolith evolutivo**: módulos independentes no backend com contratos internos claros; pronto para extrair microserviços de alto throughput (ex.: billing, notificações, IA).

### 1.2 Arquitetura lógica (alto nível)
1. **Web App (Next.js App Router)**
   - Server Components para páginas orientadas a dados.
   - Client Components apenas onde há interatividade rica (Kanban CRM, Command Palette, formulários complexos).
   - TanStack Query para cache client-side, invalidação otimista e sincronização de estado.
2. **API Layer (NestJS)**
   - Módulos: Identity, Tenant, RBAC, Billing, Finance, CRM, WorkOrders, Inventory, AI, Audit.
   - Guardas globais: autenticação, autorização RBAC + escopo de tenant.
   - Interceptores: logging estruturado, tracing, rate limit context-aware.
3. **Persistence Layer**
   - PostgreSQL 16 com estratégia **schema por tenant** + `public` para metadados globais.
   - Redis para cache, locks distribuídos, filas leves e rate limiting counters.
   - S3 compatível para fotos de OS, anexos e documentos.
4. **Async Layer**
   - BullMQ (Redis) para jobs de baixo/médio throughput.
   - Event bus (NATS/Kafka opcional por fase) para eventos críticos (faturamento, auditoria, IA, webhooks).
5. **Observability & Security**
   - OpenTelemetry + Grafana/Tempo/Loki.
   - SIEM-ready logs com trilha de auditoria imutável.

### 1.3 Arquitetura física (ambientes)
- **Staging**: cluster isolado, base dedicada, integrações sandbox.
- **Produção**: multi-AZ, HA PostgreSQL (primary + replicas), Redis com sentinel/managed, CDN global.
- **CI/CD**: GitHub Actions com gates (lint, test, SAST, migration check, smoke E2E).
- **IaC**: Terraform + Helm (Kubernetes) ou AWS CDK (alternativa).

### 1.4 Fluxo de requisição multi-tenant
1. Usuário acessa `tenantSlug.app.com`.
2. Edge middleware resolve `tenantSlug` -> `tenant_id` + `schema_name` cacheado.
3. JWT validado (issuer, audience, jti, exp).
4. API cria contexto transacional com `SET LOCAL app.current_tenant_id` e `search_path = tenant_schema,public`.
5. Policies de RLS e/ou filtro por schema garantem isolamento.
6. Auditoria registra ator, tenant, recurso, ação, payload hash e IP.

---

## 2) Estrutura de pastas (monorepo profissional)

```txt
saas-erp/
  apps/
    web/                         # Next.js (App Router, RSC, Tailwind, shadcn)
      app/
      components/
      features/
      lib/
      hooks/
      styles/
      tests/
    api/                         # NestJS
      src/
        modules/
          auth/
          tenant/
          rbac/
          billing/
          finance/
          crm/
          work-orders/
          inventory/
          ai/
          audit/
        common/
          guards/
          interceptors/
          decorators/
          filters/
          pipes/
        infra/
          db/
          cache/
          queue/
          storage/
          observability/
      test/
  packages/
    ui/                          # Design system compartilhado
    config-eslint/
    config-ts/
    logger/
    telemetry/
    sdk/                         # SDK TS para consumo da API
  database/
    migrations/
    seeds/
    policies/
    functions/
    schema.sql
  infra/
    terraform/
    kubernetes/
    github-actions/
  docs/
    architecture/
    product/
    runbooks/
```

### Convenções críticas
- `apps/api/src/modules/<dominio>` sempre com `controller`, `service`, `repository`, `dto`, `entities`, `policies`.
- Nenhum acesso direto a banco fora de repositories.
- DTO versionado para backward compatibility.
- Feature flags por tenant em tabela global.

---

## 3) Modelagem de banco de dados (PostgreSQL + multi-tenant)

### 3.1 Estratégia
- **public schema**: identidade global, tenants, planos, billing global, catálogos e controle de provisioning.
- **tenant schema** (`tenant_<uuid_sanitizado>`): entidades de negócio (financeiro, CRM, OS, estoque, auditoria local).
- Provisionamento automático via job transacional com template de schema e migrações tenant-aware.

### 3.2 Entidades globais (public)
- `tenants`
- `tenant_domains`
- `users`
- `memberships`
- `roles`, `permissions`, `role_permissions`
- `plans`, `subscriptions`, `invoices`, `payment_events`
- `feature_flags`
- `mfa_factors`
- `api_keys`

### 3.3 Entidades por tenant
- **Core**: `companies`, `branches`, `cost_centers`, `audit_logs`
- **Financeiro**: `accounts_payable`, `accounts_receivable`, `cash_transactions`, `bank_accounts`, `reconciliations`, `financial_snapshots`, `dre_entries`
- **CRM**: `leads`, `contacts`, `organizations`, `pipelines`, `pipeline_stages`, `deals`, `activities`
- **OS**: `service_orders`, `service_order_statuses`, `service_order_items`, `service_order_photos`, `service_checklists`, `service_signatures`, `warranty_terms`
- **Estoque**: `products`, `suppliers`, `stock_movements`, `purchase_orders`, `inventory_balances`
- **IA**: `ai_summaries`, `ai_predictions`, `ai_recommendations`

### 3.4 Índices e performance
- Índices compostos por data/status em entidades financeiras e OS.
- Índices parciais para status ativos (`WHERE deleted_at IS NULL`).
- Full-text index para busca global em leads, OS e produtos.
- Materialized views para dashboards e DRE por período.

### 3.5 Estratégia de consulta
- Paginação cursor-based para listas críticas.
- Snapshots pré-calculados (diário/semanal) para painéis executivos.
- Caching por tenant + chave semântica (`tenant:{id}:dashboard:v{n}`).

---

## 4) Wireframes das telas principais (textuais)

### 4.1 Shell principal (desktop)
```txt
┌────────────────────────────────────────────────────────────────────────────┐
│ Topbar: [Tenant Switcher] [Global Search/⌘K] [Quick Actions] [Profile]   │
├───────────────┬────────────────────────────────────────────────────────────┤
│ Sidebar       │ Dashboard                                                   │
│ - Home        │ ┌ KPI Row: Lucro | Receita | Ticket Médio | Conversão ┐   │
│ - Financeiro  │ └───────────────────────────────────────────────────────┘   │
│ - CRM         │ ┌ Insights IA: Previsão Receita + Alertas Caixa ┐         │
│ - OS          │ └─────────────────────────────────────────────────┘         │
│ - Estoque     │ ┌ Técnicos Produtivos ┐ ┌ Funil Vendas ┐ ┌ OS SLA ┐      │
│ - Relatórios  │ └─────────────────────┘ └──────────────┘ └────────┘      │
│ - Config      │                                                             │
└───────────────┴────────────────────────────────────────────────────────────┘
```

### 4.2 Command Palette (CTRL/CMD + K)
- Busca universal: clientes, OS, faturas, leads, comandos.
- Atalhos de ação: “Criar OS”, “Receber pagamento”, “Novo lead”, “Conciliação”.
- Escopo por tenant obrigatório e exibido no cabeçalho.

### 4.3 Tela de Ordem de Serviço (principal)
```txt
Header: OS #SO-2026-00128 | Status: Em Atendimento | SLA: 4h
Tabs: Resumo | Checklist Técnico | Peças | Fotos | Assinatura | Histórico
Right Rail: Timeline + Custos + Garantia + Botões IA (Resumo / Próxima ação)
Footer Actions: Salvar rascunho | Concluir serviço | Gerar cobrança
```

### 4.4 Financeiro (contas + fluxo)
- Lista com filtros avançados (competência, centro de custo, status, método).
- Split view: tabela densa + painel lateral de conciliação.
- DRE com drill-down por conta contábil operacional.

---

## 5) Fluxos de usuários

### 5.1 Onboarding tenant
1. Signup da empresa + dono da conta.
2. Criação de tenant, schema, plano trial e permissões iniciais.
3. Wizard: dados da empresa, logo, centro de custos padrão, status OS padrão.
4. Convite de equipe por e-mail com RBAC mínimo.

### 5.2 Fluxo de OS end-to-end
1. Abertura OS por cliente/equipamento.
2. Definição checklist técnico e peças previstas.
3. Técnico executa atendimento mobile-first, anexa fotos e assinatura digital.
4. OS concluída gera conta a receber e atualização de estoque.
5. Dashboard atualiza produtividade e margem por OS.

### 5.3 Fluxo financeiro robusto
1. Lançamentos manuais + importação OFX/CSV.
2. Conciliação assistida com regras e sugestão IA.
3. Fechamento mensal com snapshots e DRE.
4. Alertas de inadimplência e bloqueio progressivo por política de plano.

---

## 6) Design System (premium dark mode)

### 6.1 Tokens de design
- **Cores**
  - `bg/base`: `#0B0D12`
  - `bg/surface`: `#11141B`
  - `bg/elevated`: `#171B24`
  - `text/primary`: `#F5F7FA`
  - `text/secondary`: `#A5ADBA`
  - `accent/brand`: `#7C5CFF`
  - `success`: `#27C383`, `warning`: `#FFB020`, `danger`: `#FF5D5D`
- **Tipografia**
  - Inter/Geist Sans, escala 12/14/16/20/24/32
- **Espaçamento**
  - Sistema 4px com uso predominante 8/12/16/24/32
- **Raios/sombras**
  - Radius 10/14
  - Sombras sutis em camadas para profundidade premium

### 6.2 Componentes base (shadcn/ui)
- Buttons, Inputs, Select, Dialog, Sheet, Tabs, DataTable, Command, Toast.
- Estados completos: default/hover/focus/disabled/loading/error.
- Acessibilidade: contraste AA+, foco visível, navegação por teclado.

### 6.3 Padrões UX obrigatórios
- Navegação lateral persistente com agrupamento por contexto.
- Tempo de ação percebido < 100ms com skeletons e optimistic UI.
- Feedback contínuo de status de processamento (jobs, IA, exportações).

---

## 7) Estratégia multi-tenant detalhada

### 7.1 Modelo `tenant por schema`
- Cada tenant possui schema próprio com mesma estrutura.
- Migrações executam em ondas:
  1. validar em staging espelhado,
  2. canário em tenants internos,
  3. rollout progressivo com observabilidade.

### 7.2 Isolamento de dados
- Resolução de tenant por domínio/subdomínio + claims do token.
- `search_path` fixado por conexão/transação e não controlado por input do usuário.
- Validação dupla no app layer e db layer.
- Proibição de queries sem tenant context via lint custom de repository.

### 7.3 Escala para milhares de tenants
- Pooling com PgBouncer (transaction pooling).
- Catálogo de tenants cacheado em Redis.
- Sharding futuro por grupo de schemas em clusters distintos (tenant placement).
- Estratégia de arquivamento frio para tenants inativos.

### 7.4 Backup e recuperação
- PITR (Point-in-time recovery) global.
- Restore seletivo por schema para incidentes de tenant específico.
- Testes trimestrais de DR (disaster recovery).

---

## 8) Stack final recomendada

### Frontend
- Next.js 15 + React 19 + TypeScript
- Tailwind + shadcn/ui + Radix
- TanStack Query + Zustand (estado local complexo)
- React Hook Form + Zod

### Backend
- NestJS + TypeScript
- Prisma (com SQL raw controlado para casos avançados) **ou** Drizzle para SQL-centric
- Redis + BullMQ
- OpenTelemetry SDK

### Dados e Infra
- PostgreSQL 16 (RDS/Cloud SQL)
- S3 (ou compatível)
- Kubernetes (EKS/GKE) + NGINX ingress
- GitHub Actions + ArgoCD (GitOps)
- Sentry + Grafana stack

---

## 9) Plano de desenvolvimento (MVP -> escala)

### Fase 0 (2-3 semanas): Foundation
- Monorepo, autenticação, tenant provisioning, RBAC base.
- Design system dark mode + shell UI + command palette.
- Observabilidade mínima, CI/CD e ambientes.

### Fase 1 (4-6 semanas): MVP operacional
- Módulo OS completo (abertura, status, checklist, fotos, assinatura).
- Financeiro núcleo (contas a pagar/receber + fluxo de caixa).
- CRM básico (leads + pipeline).
- Dashboard acionável com 5 KPIs estratégicos.

### Fase 2 (4-5 semanas): robustez e monetização
- Billing recorrente, planos, trials, bloqueio por inadimplência.
- Conciliação financeira e DRE.
- Estoque integrado à OS.
- Auditoria avançada + export compliance.

### Fase 3 (6+ semanas): escala enterprise
- IA preditiva (receita, compra estoque), automações, benchmark por segmento.
- Modo multi-filial, permissões granulares por unidade.
- SSO/SAML, SCIM, API pública e webhooks robustos.

---

## 10) Principais riscos técnicos

1. **Tenant leakage** por falha de contexto em query custom.
2. **Complexidade de migração** em milhares de schemas.
3. **Latência em dashboards** sem estratégia de snapshot/materialização.
4. **Billing inconsistente** em webhooks idempotentes mal projetados.
5. **Crescimento de auditoria/log** sem política de retenção por camada.

### Mitigações
- Testes automatizados de isolamento multi-tenant em cada PR.
- Migration orchestrator com rollback e health gates.
- Tabelas de snapshot incremental e refresh assíncrono.
- Chaves idempotentes obrigatórias em eventos externos.
- Tiering de logs (quente/morno/frio) com TTL e archive.

---

## 11) Boas práticas de engenharia

- Clean Architecture pragmática por domínio.
- Contratos versionados e depreciação planejada.
- Feature flags para rollout controlado.
- Testes: unitário, integração (db real), contrato e E2E crítico.
- Segurança shift-left: SAST, DAST, dependency scanning, secrets scanning.
- Observabilidade desde o primeiro commit (logs, métricas, traces correlacionados).

---

## 12) Estratégias para evitar dívida técnica

1. **Definition of Done rígido** com critérios não-funcionais (latência, segurança, cobertura).
2. **ADR (Architecture Decision Records)** para decisões de impacto.
3. **Política de refatoração contínua** (20% da capacidade por sprint para saúde técnica).
4. **Catálogo de módulos e ownership explícito** (time responsável por domínio).
5. **Padrões de código e lint arquitetural** impedindo atalhos perigosos.
6. **Observabilidade orientada a produto**: métrica técnica e de negócio lado a lado.

---

## Segurança obrigatória (implementação proposta)

- **RLS**: aplicado em tabelas globais sensíveis (`memberships`, `api_keys`, `mfa_factors`) e opcionalmente em tenants high-compliance.
- **Criptografia**:
  - em trânsito: TLS 1.3
  - em repouso: KMS managed keys
  - campo sensível: `pgcrypto` para documentos/segredos
- **Rate limiting**:
  - por IP, usuário e tenant
  - regras diferenciadas por rota (auth, export, webhook)
- **MFA**:
  - TOTP obrigatório para perfis administrativos
  - backup codes com rotação
- **Auditoria**:
  - trilha imutável append-only
  - hash encadeado para detecção de adulteração

---

## Recursos avançados com IA (nativos)

1. **Geração de descrições automáticas**
   - OS: resumo técnico com base em checklist, fotos e peças.
2. **Resumo financeiro inteligente**
   - síntese executiva semanal por tenant + alertas de risco de caixa.
3. **Sugestão de compras de estoque**
   - previsão de ruptura baseada em sazonalidade + OS abertas.
4. **Previsão de receita**
   - modelo híbrido (série temporal + sinais de pipeline CRM).

### Guardrails de IA
- PII masking antes de enviar contexto a provedores externos.
- Registro de prompts/respostas para auditoria interna.
- Política de fallback determinístico quando IA indisponível.

---

## Conclusão executiva
Este blueprint estabelece uma base de produto SaaS ERP com padrão enterprise, preparado para escala real, monetização recorrente, isolamento multi-tenant forte e experiência premium dark mode, com governança técnica para crescimento sustentável e baixa dívida ao longo de anos de evolução do produto.
