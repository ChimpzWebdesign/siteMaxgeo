-- ERP SaaS Enterprise - PostgreSQL schema baseline
-- Strategy: public schema for global tenancy and tenant metadata.
-- Tenant business data lives in dedicated schemas provisioned per tenant.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =========================
-- GLOBAL (public)
-- =========================

CREATE TABLE IF NOT EXISTS public.tenants (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  slug TEXT NOT NULL UNIQUE,
  legal_name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  schema_name TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email CITEXT NOT NULL UNIQUE,
  full_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  is_global_admin BOOLEAN NOT NULL DEFAULT FALSE,
  last_login_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.memberships (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role_key TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.plans (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  monthly_price_cents INTEGER NOT NULL,
  annual_price_cents INTEGER,
  limits_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.subscriptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  plan_id UUID NOT NULL REFERENCES public.plans(id),
  status TEXT NOT NULL,
  trial_ends_at TIMESTAMPTZ,
  current_period_start TIMESTAMPTZ,
  current_period_end TIMESTAMPTZ,
  cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.mfa_factors (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  factor_type TEXT NOT NULL,
  secret_encrypted TEXT NOT NULL,
  is_primary BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_memberships_tenant_user ON public.memberships(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_tenant_status ON public.subscriptions(tenant_id, status);

-- Optional RLS for global tables that reference tenant context
ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

CREATE POLICY memberships_tenant_isolation
  ON public.memberships
  USING (tenant_id::text = current_setting('app.current_tenant_id', true));

-- =========================
-- TENANT TEMPLATE (example)
-- In production, this block is executed per tenant schema.
-- =========================

CREATE SCHEMA IF NOT EXISTS tenant_template;

CREATE TABLE IF NOT EXISTS tenant_template.audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  actor_user_id UUID,
  action TEXT NOT NULL,
  resource_type TEXT NOT NULL,
  resource_id TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.cost_centers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (code)
);

CREATE TABLE IF NOT EXISTS tenant_template.accounts_payable (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  supplier_name TEXT NOT NULL,
  amount_cents BIGINT NOT NULL,
  due_date DATE NOT NULL,
  status TEXT NOT NULL,
  cost_center_id UUID REFERENCES tenant_template.cost_centers(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.accounts_receivable (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_name TEXT NOT NULL,
  amount_cents BIGINT NOT NULL,
  due_date DATE NOT NULL,
  status TEXT NOT NULL,
  cost_center_id UUID REFERENCES tenant_template.cost_centers(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.cash_transactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  transaction_date DATE NOT NULL,
  amount_cents BIGINT NOT NULL,
  direction TEXT NOT NULL,
  category TEXT NOT NULL,
  reference_type TEXT,
  reference_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.leads (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  source TEXT,
  score INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'new',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.pipeline_stages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  win_probability NUMERIC(5,2) NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.deals (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  lead_id UUID REFERENCES tenant_template.leads(id),
  stage_id UUID REFERENCES tenant_template.pipeline_stages(id),
  title TEXT NOT NULL,
  value_cents BIGINT NOT NULL,
  expected_close_date DATE,
  status TEXT NOT NULL DEFAULT 'open',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.products (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sku TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  unit_cost_cents BIGINT NOT NULL,
  avg_cost_cents BIGINT NOT NULL,
  current_stock NUMERIC(14,3) NOT NULL DEFAULT 0,
  reorder_point NUMERIC(14,3) NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.stock_movements (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  product_id UUID NOT NULL REFERENCES tenant_template.products(id),
  movement_type TEXT NOT NULL,
  quantity NUMERIC(14,3) NOT NULL,
  unit_cost_cents BIGINT,
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.service_orders (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code TEXT NOT NULL UNIQUE,
  customer_name TEXT NOT NULL,
  equipment_description TEXT,
  issue_description TEXT,
  status TEXT NOT NULL,
  opened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_at TIMESTAMPTZ,
  assigned_technician_id UUID,
  warranty_until DATE
);

CREATE TABLE IF NOT EXISTS tenant_template.service_order_checklists (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  service_order_id UUID NOT NULL REFERENCES tenant_template.service_orders(id) ON DELETE CASCADE,
  item_label TEXT NOT NULL,
  is_checked BOOLEAN NOT NULL DEFAULT FALSE,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.service_order_parts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  service_order_id UUID NOT NULL REFERENCES tenant_template.service_orders(id) ON DELETE CASCADE,
  product_id UUID REFERENCES tenant_template.products(id),
  quantity NUMERIC(14,3) NOT NULL,
  unit_price_cents BIGINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.service_order_photos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  service_order_id UUID NOT NULL REFERENCES tenant_template.service_orders(id) ON DELETE CASCADE,
  object_key TEXT NOT NULL,
  content_type TEXT NOT NULL,
  uploaded_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.service_order_signatures (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  service_order_id UUID NOT NULL UNIQUE REFERENCES tenant_template.service_orders(id) ON DELETE CASCADE,
  signer_name TEXT NOT NULL,
  signature_object_key TEXT NOT NULL,
  signed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tenant_template.ai_predictions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  prediction_type TEXT NOT NULL,
  period_start DATE,
  period_end DATE,
  payload JSONB NOT NULL,
  confidence NUMERIC(5,2),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ap_due_status ON tenant_template.accounts_payable(due_date, status);
CREATE INDEX IF NOT EXISTS idx_ar_due_status ON tenant_template.accounts_receivable(due_date, status);
CREATE INDEX IF NOT EXISTS idx_so_status_opened ON tenant_template.service_orders(status, opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_leads_status_created ON tenant_template.leads(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stock_movements_product_date ON tenant_template.stock_movements(product_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_created ON tenant_template.audit_logs(created_at DESC);
