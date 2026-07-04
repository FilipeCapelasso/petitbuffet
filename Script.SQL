-- ============================================================================
-- PETIT BUFFET PREMIUM — SCRIPT SQL ÚNICO, COMPLETO E DEFINITIVO (Supabase)
-- Projeto: ejdboszoswqvgsjsrcmf
-- ============================================================================
-- NOVIDADES VS VERSÕES ANTERIORES:
--   • CORREÇÃO do erro "check constraint pedidos_status_pedido_check violated":
--     O UPDATE de normalização agora roda ANTES de adicionar a constraint.
--   • CORREÇÃO do tipo de `itens`: converte jsonb → text automaticamente.
--   • Tabela `clientes`: login automático sem senha (primeiro nome + telefone).
--   • 5 etapas do pedido: realizado → confirmado → preparo → aguardando2 → pronto.
--   • Tabela `pix_cobrancas` + função get_payment_status() para PIX automático.
--   • Seed completo: categorias, produtos, preços com "Pacote" (não "Cento"/"Centro").
--   • Migração automática: renomeia "Cento"/"Centos" já existentes no banco para
--     "Pacote"/"Pacotes", preservando qualquer customização feita pelo admin.
--
-- COMO RODAR:
--   Supabase → SQL Editor → New query → cole TUDO → Run.
--   100% idempotente: pode rodar várias vezes, não apaga nem duplica nada.
--
-- DEPOIS DE RODAR:
--   1) Authentication → Users → crie o usuário admin (email + senha).
--   2) Copie o UUID e rode:  insert into public.admins (user_id) values ('UUID');
--   3) PIX: verifique a Edge Function "loop-api" e o secret do Mercado Pago.
-- ============================================================================

create extension if not exists pgcrypto;

-- ============================================================================
-- 0) ADMINS + is_admin()  ← VEM PRIMEIRO (outros depende desta função)
-- ============================================================================
create table if not exists public.admins (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  nome      text,
  criado_em timestamptz not null default now()
);
alter table public.admins enable row level security;

drop policy if exists "admins_leem_a_si_mesmos"  on public.admins;
drop policy if exists "admins_sem_acesso_direto" on public.admins;
create policy "admins_sem_acesso_direto" on public.admins for all using (false);

create or replace function public.is_admin()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ============================================================================
-- 1) CLIENTES  —  cadastro/login automático sem senha
--    Telefone = identidade do cliente (upsert por telefone = "login")
-- ============================================================================
create table if not exists public.clientes (
  telefone      text primary key,
  nome          text not null,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.clientes enable row level security;

drop policy if exists "clientes_insert_publica" on public.clientes;
drop policy if exists "clientes_update_publica" on public.clientes;
drop policy if exists "clientes_select_publica" on public.clientes;

create policy "clientes_insert_publica" on public.clientes for insert with check (true);
create policy "clientes_update_publica" on public.clientes for update using (true);
create policy "clientes_select_publica" on public.clientes for select using (true);

-- ============================================================================
-- 2) CATEGORIAS
-- ============================================================================
create table if not exists public.categorias (
  id        text primary key,
  nome      text not null,
  ordem     int  not null default 0,
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);
alter table public.categorias enable row level security;

drop policy if exists "categorias_leitura_publica" on public.categorias;
drop policy if exists "categorias_admin_escreve"   on public.categorias;
create policy "categorias_leitura_publica" on public.categorias for select using (true);
create policy "categorias_admin_escreve"   on public.categorias for all
  using (public.is_admin()) with check (public.is_admin());

-- ============================================================================
-- 3) PRODUTOS
-- ============================================================================
create table if not exists public.produtos (
  id            text primary key,
  categoria_id  text references public.categorias(id) on delete set null,
  nome          text not null,
  icone         text default '◈',
  imagem_url    text,
  descricao     text default '',
  ordem         int  not null default 0,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists idx_produtos_categoria on public.produtos(categoria_id);
alter table public.produtos enable row level security;

drop policy if exists "produtos_leitura_publica" on public.produtos;
drop policy if exists "produtos_admin_escreve"   on public.produtos;
create policy "produtos_leitura_publica" on public.produtos for select using (true);
create policy "produtos_admin_escreve"   on public.produtos for all
  using (public.is_admin()) with check (public.is_admin());

-- ============================================================================
-- 4) CENTROS  (preços por tamanho — "Pacote 100", "Pacote Médio" etc.)
--    Obs.: o nome da TABELA continua "centros" de propósito — é só o slug
--    interno usado pelo site/edge function; o texto que o cliente vê (label)
--    é que virou "Pacote".
-- ============================================================================
create table if not exists public.centros (
  produto_id text    not null,
  tier_id    text    not null,
  label      text,
  quantidade numeric,
  preco      numeric not null default 0,
  ativo      boolean not null default true,
  primary key (produto_id, tier_id)
);
alter table public.centros enable row level security;

drop policy if exists "centros_leitura_publica" on public.centros;
drop policy if exists "centros_admin_escreve"   on public.centros;
create policy "centros_leitura_publica" on public.centros for select using (true);
create policy "centros_admin_escreve"   on public.centros for all
  using (public.is_admin()) with check (public.is_admin());

-- ============================================================================
-- 5) PRODUTOS_ESTOQUE
-- ============================================================================
create table if not exists public.produtos_estoque (
  produto_id text    primary key,
  disponivel boolean not null default true
);
alter table public.produtos_estoque enable row level security;

drop policy if exists "estoque_leitura_publica" on public.produtos_estoque;
drop policy if exists "estoque_admin_escreve"   on public.produtos_estoque;
create policy "estoque_leitura_publica" on public.produtos_estoque for select using (true);
create policy "estoque_admin_escreve"   on public.produtos_estoque for all
  using (public.is_admin()) with check (public.is_admin());

-- ============================================================================
-- 6) CONFIGURACOES
-- ============================================================================
create table if not exists public.configuracoes (
  chave         text primary key,
  valor         text,
  atualizado_em timestamptz not null default now()
);
alter table public.configuracoes enable row level security;

drop policy if exists "config_leitura_publica" on public.configuracoes;
drop policy if exists "config_admin_escreve"   on public.configuracoes;
create policy "config_leitura_publica" on public.configuracoes for select using (true);
create policy "config_admin_escreve"   on public.configuracoes for all
  using (public.is_admin()) with check (public.is_admin());

insert into public.configuracoes (chave, valor) values
  ('whatsapp',             '6892626612'),
  ('pix_key',              '6892626612'),
  ('usar_planilha_backup', 'false')
on conflict (chave) do nothing;

-- ============================================================================
-- 7) PEDIDOS  ← ATENÇÃO: ordem das operações é crítica aqui
-- ============================================================================

-- A) Cria a tabela com schema correto (se não existir)
create table if not exists public.pedidos (
  pedido            text primary key,
  nome              text,
  telefone          text,
  endereco          text,
  itens             text,        -- TEXTO puro (o site manda string formatada)
  centro_detalhes   jsonb,
  total             numeric default 0,
  sinal             numeric default 0,
  saldo             numeric default 0,
  forma_pagamento   text,
  tipo_agendamento  text,
  data_agendada     text,
  hora_agendada     text,
  status_pagamento  text not null default 'pendente',
  status_pedido     text not null default 'realizado',
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now()
);

-- B) Garante colunas que podem faltar em bancos mais antigos
alter table public.pedidos add column if not exists status_pedido    text not null default 'realizado';
alter table public.pedidos add column if not exists atualizado_em    timestamptz   not null default now();
alter table public.pedidos add column if not exists centro_detalhes  jsonb;
alter table public.pedidos add column if not exists tipo_agendamento text;

-- C) Converte itens de jsonb → text se o banco antigo usava jsonb
--    *** CORREÇÃO: o site manda texto puro; jsonb rejeitava isso ***
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'pedidos'
      and column_name = 'itens' and data_type = 'jsonb'
  ) then
    alter table public.pedidos alter column itens type text
      using case
        when itens is null then null
        when jsonb_typeof(itens) = 'string' then itens #>> '{}'
        else itens::text
      end;
    raise notice 'pedidos.itens convertido de jsonb para text com sucesso.';
  end if;
end $$;

-- D) Remove a constraint ANTES do UPDATE para não bloquear a limpeza
alter table public.pedidos drop constraint if exists pedidos_status_pedido_check;

-- E) *** CORREÇÃO DO ERRO 23514 ***
--    Normaliza status_pedido PRIMEIRO — antes de criar a constraint.
--    O banco antigo usava valores livres como 'pedido recebido', 'em preparo', etc.
--    Estes são todos mapeados para os 6 valores válidos do novo fluxo.
update public.pedidos
   set status_pedido = case
     -- Já válidos: mantém
     when status_pedido in ('realizado','confirmado','preparo','aguardando2','pronto','cancelado')
          then status_pedido
     -- Mapeamento de valores antigos
     when status_pedido ilike '%recebid%'
       or status_pedido = ''                   then 'realizado'
     when status_pedido ilike '%confirm%'       then 'confirmado'
     when status_pedido ilike '%prepar%'        then 'preparo'
     when (status_pedido ilike '%2%'
       and status_pedido ilike '%pag%')
       or status_pedido ilike '%segund%'
       or status_pedido ilike '%aguard%'        then 'aguardando2'
     when status_pedido ilike '%pronto%'
       or status_pedido ilike '%reserv%'        then 'pronto'
     when status_pedido ilike '%cancel%'
       or status_pedido ilike '%recus%'         then 'cancelado'
     when status_pedido ilike '%finaliz%'
       or status_pedido ilike '%conclu%'        then 'pronto'
     -- Qualquer outro valor desconhecido → realizado
     else 'realizado'
   end;

-- F) Agora sim: adiciona a constraint (todas as linhas já estão limpas)
alter table public.pedidos add constraint pedidos_status_pedido_check
  check (status_pedido in ('realizado','confirmado','preparo','aguardando2','pronto','cancelado'));

-- Índices
create index if not exists idx_pedidos_criado_em     on public.pedidos(criado_em desc);
create index if not exists idx_pedidos_telefone      on public.pedidos(telefone);
create index if not exists idx_pedidos_status_pedido on public.pedidos(status_pedido);

alter table public.pedidos enable row level security;

drop policy if exists "pedidos_insercao_publica" on public.pedidos;
drop policy if exists "pedidos_update_publica"   on public.pedidos;
drop policy if exists "pedidos_update_admin"     on public.pedidos;
drop policy if exists "pedidos_leitura_publica"  on public.pedidos;
drop policy if exists "pedidos_leitura_admin"    on public.pedidos;
drop policy if exists "pedidos_admin_delete"     on public.pedidos;

create policy "pedidos_insercao_publica" on public.pedidos for insert with check (true);
create policy "pedidos_update_publica"   on public.pedidos for update using (true);
create policy "pedidos_leitura_publica"  on public.pedidos for select using (true);
-- Sem esta política, o botão "Limpar Todos os Pedidos" do admin roda sem erro
-- mas apaga ZERO linhas (RLS bloqueia silenciosamente qualquer DELETE sem policy).
create policy "pedidos_admin_delete" on public.pedidos for delete using (public.is_admin());

-- ============================================================================
-- 8) AVALIACOES
-- ============================================================================
create table if not exists public.avaliacoes (
  id        serial primary key,
  nome      text,
  texto     text,
  nota      int check (nota between 1 and 5),
  pedido    text,
  aprovado  boolean not null default false,
  criado_em timestamptz not null default now()
);
alter table public.avaliacoes enable row level security;

drop policy if exists "avaliacoes_insercao_publica"  on public.avaliacoes;
drop policy if exists "avaliacoes_leitura_aprovadas" on public.avaliacoes;
drop policy if exists "avaliacoes_admin_update"      on public.avaliacoes;
drop policy if exists "avaliacoes_admin_escreve"     on public.avaliacoes;
drop policy if exists "avaliacoes_admin_delete"      on public.avaliacoes;

create policy "avaliacoes_insercao_publica"  on public.avaliacoes for insert with check (true);
create policy "avaliacoes_leitura_aprovadas" on public.avaliacoes for select
  using (aprovado = true or public.is_admin());
create policy "avaliacoes_admin_update"      on public.avaliacoes for update
  using (public.is_admin()) with check (public.is_admin());
create policy "avaliacoes_admin_delete"      on public.avaliacoes for delete
  using (public.is_admin());

-- ============================================================================
-- 9) REGISTROS  (log de auditoria)
-- ============================================================================
create table if not exists public.registros (
  id        serial primary key,
  acao      text,
  entidade  text,
  detalhe   text,
  ator      text,
  criado_em timestamptz not null default now()
);
alter table public.registros enable row level security;

drop policy if exists "registros_insercao_admin"   on public.registros;
drop policy if exists "registros_insercao_publica" on public.registros;
drop policy if exists "registros_leitura_admin"    on public.registros;
drop policy if exists "registros_admin_delete"     on public.registros;

create policy "registros_insercao_publica" on public.registros for insert with check (true);
create policy "registros_leitura_admin"    on public.registros for select
  using (public.is_admin());
-- Sem esta política, o botão "Limpar Todos os Registros" do admin roda sem erro
-- mas apaga ZERO linhas (RLS bloqueia silenciosamente qualquer DELETE sem policy).
create policy "registros_admin_delete" on public.registros for delete using (public.is_admin());

-- ============================================================================
-- 10) CARRINHOS_ABANDONADOS
-- ============================================================================
create table if not exists public.carrinhos_abandonados (
  token         text primary key,
  nome          text,
  telefone      text,
  itens         jsonb,
  total         numeric,
  atualizado_em timestamptz not null default now(),
  recuperado    boolean not null default false
);
alter table public.carrinhos_abandonados enable row level security;

drop policy if exists "carrinhos_insercao_publica" on public.carrinhos_abandonados;
drop policy if exists "carrinhos_update_publica"   on public.carrinhos_abandonados;
drop policy if exists "carrinhos_leitura_admin"    on public.carrinhos_abandonados;

create policy "carrinhos_insercao_publica" on public.carrinhos_abandonados for insert with check (true);
create policy "carrinhos_update_publica"   on public.carrinhos_abandonados for update using (true);
create policy "carrinhos_leitura_admin"    on public.carrinhos_abandonados for select
  using (public.is_admin());

-- ============================================================================
-- 11) PIX_COBRANCAS + get_payment_status()
-- ============================================================================
create table if not exists public.pix_cobrancas (
  id              serial primary key,
  pedido          text    not null,
  token           text    not null,
  mp_payment_id   text,
  status          text    not null default 'pendente'
                    check (status in ('pendente','pago','cancelado','expirado')),
  expires_at      timestamptz,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
create index if not exists idx_pix_cobrancas_pedido_token on public.pix_cobrancas(pedido, token);

alter table public.pix_cobrancas enable row level security;
drop policy if exists "pix_cobrancas_sem_acesso_direto" on public.pix_cobrancas;
create policy "pix_cobrancas_sem_acesso_direto" on public.pix_cobrancas for all using (false);

create or replace function public.get_payment_status(p_order_id text, p_token text)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare v_status text;
begin
  select pc.status into v_status
    from public.pix_cobrancas pc
   where pc.pedido = p_order_id and pc.token = p_token
   order by pc.criado_em desc limit 1;
  if v_status is null then return jsonb_build_object('found', false); end if;
  return jsonb_build_object('found', true, 'status', v_status);
end;
$$;

-- ============================================================================
-- 12) TRIGGERS — atualizado_em automático
-- ============================================================================
create or replace function public.tocar_atualizado_em()
returns trigger language plpgsql as $$
begin new.atualizado_em = now(); return new; end;
$$;

drop trigger if exists trg_pedidos_atualizado_em       on public.pedidos;
drop trigger if exists trg_clientes_atualizado_em      on public.clientes;
drop trigger if exists trg_pix_cobrancas_atualizado_em on public.pix_cobrancas;

create trigger trg_pedidos_atualizado_em
  before update on public.pedidos
  for each row execute function public.tocar_atualizado_em();

create trigger trg_clientes_atualizado_em
  before update on public.clientes
  for each row execute function public.tocar_atualizado_em();

create trigger trg_pix_cobrancas_atualizado_em
  before update on public.pix_cobrancas
  for each row execute function public.tocar_atualizado_em();

-- ============================================================================
-- 13) STORAGE — bucket "produtos" para fotos dos produtos
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('produtos', 'produtos', true)
on conflict (id) do nothing;

drop policy if exists "produtos_imagens_leitura_publica" on storage.objects;
drop policy if exists "produtos_imagens_admin_escreve"   on storage.objects;
drop policy if exists "produtos_imagens_admin_atualiza"  on storage.objects;
drop policy if exists "produtos_imagens_admin_apaga"     on storage.objects;

create policy "produtos_imagens_leitura_publica" on storage.objects
  for select using (bucket_id = 'produtos');
create policy "produtos_imagens_admin_escreve" on storage.objects
  for insert with check (bucket_id = 'produtos' and public.is_admin());
create policy "produtos_imagens_admin_atualiza" on storage.objects
  for update using (bucket_id = 'produtos' and public.is_admin());
create policy "produtos_imagens_admin_apaga" on storage.objects
  for delete using (bucket_id = 'produtos' and public.is_admin());

-- ============================================================================
-- 14) SEED — catálogo inicial (só insere se ainda não existe)
-- ============================================================================
insert into public.categorias (id, nome, ordem) values
  ('centros', 'Pacotes', 1),
  ('lanches', 'Lanches', 2)
on conflict (id) do nothing;

insert into public.produtos (id, categoria_id, nome, icone, descricao, ordem) values
  ('hamburguer',     'centros', 'Hambúrguer',          '◉', 'Carrinho de hambúrgueres artesanais montados na hora.',               1),
  ('cachorroquente', 'centros', 'Cachorro Quente',     '▭', 'Cachorro quente gourmet com acompanhamentos variados.',               2),
  ('pizza',          'centros', 'Pizza Artesanal',     '◐', 'Pizzas artesanais assadas na hora para encantar qualquer evento.',    3),
  ('picole',         'centros', 'Picolé Gourmet',      '◒', 'Picolés artesanais com sabores premium e apresentação impecável.',   4),
  ('brigadeiro',     'centros', 'Brigadeiro no Tacho', '●', 'Brigadeiro cremoso feito no tacho, servido com elegância.',           5),
  ('pipoca',         'centros', 'Pipoca Doce',         '◍', 'Pipoca caramelizada e temperada, irresistível para qualquer evento.', 6),
  ('algodao',        'centros', 'Algodão Doce',        '◯', 'Algodão doce colorido, macio e encantador para todas as idades.',    7),
  ('sanduiche',      'lanches', 'Sanduíche Natural',   '▱', 'Sanduíches naturais frescos, saudáveis e preparados com carinho.',    1),
  ('empada',         'lanches', 'Empadas',             '◔', 'Empadas artesanais crocantes com recheios sofisticados e saborosos.', 2)
on conflict (id) do nothing;

insert into public.centros (produto_id, tier_id, label, quantidade, preco, ativo) values
  ('hamburguer',     'p', 'Pacote 100',     100,   600, true),
  ('hamburguer',     'm', 'Pacote 150',     150,   870, true),
  ('hamburguer',     'g', 'Pacote 200',     200,  1120, true),
  ('cachorroquente', 'p', 'Pacote 80',       80,   480, true),
  ('cachorroquente', 'm', 'Pacote 120',     120,   696, true),
  ('cachorroquente', 'g', 'Pacote 160',     160,   896, true),
  ('pizza',          'p', 'Pacote 80',       80,   480, true),
  ('pizza',          'm', 'Pacote 120',     120,   696, true),
  ('pizza',          'g', 'Pacote 160',     160,   896, true),
  ('picole',         'p', 'Pacote 50',       50,   250, true),
  ('picole',         'm', 'Pacote 100',     100,   475, true),
  ('picole',         'g', 'Pacote 150',     150,   675, true),
  ('brigadeiro',     'p', 'Pacote Pequeno', null,  185, true),
  ('brigadeiro',     'm', 'Pacote Médio',   null,  220, true),
  ('brigadeiro',     'g', 'Pacote Grande',  null,  250, true),
  ('pipoca',         'p', 'Pacote 80',       80,   320, true),
  ('pipoca',         'm', 'Pacote 120',     120,   444, true),
  ('pipoca',         'g', 'Pacote 160',     160,   544, true),
  ('algodao',        'p', 'Pacote 80',       80,   320, true),
  ('algodao',        'm', 'Pacote 120',     120,   444, true),
  ('algodao',        'g', 'Pacote 160',     160,   544, true),
  ('sanduiche',      'p', 'Pacote 30',       30,   240, true),
  ('sanduiche',      'm', 'Pacote 50',       50,   380, true),
  ('sanduiche',      'g', 'Pacote 80',       80,   560, true),
  ('empada',         'p', 'Pacote 30',       30,   150, true),
  ('empada',         'm', 'Pacote 60',       60,   270, true),
  ('empada',         'g', 'Pacote 100',     100,   420, true)
on conflict (produto_id, tier_id) do nothing;

-- ============================================================================
-- 15) MIGRAÇÃO DE TERMINOLOGIA — "Cento"/"Centos" → "Pacote"/"Pacotes"
-- ============================================================================
-- Os inserts do SEED acima só valem para quem está rodando isso pela primeira
-- vez (o "on conflict do nothing" não toca em quem já existe). Se você já
-- rodou uma versão anterior deste script, seus dados já têm "Cento" gravado
-- de verdade nas tabelas — este bloco corrige isso agora, com segurança:
--   • Troca só a PALAVRA "Cento"/"Centos" dentro do texto (preserva o resto).
--   • Se você renomeou algo manualmente pelo painel (ex.: "Cento Família"),
--     vira "Pacote Família" — a customização não se perde.
--   • Idempotente: rodar de novo não faz nada (não há mais "Cento" pra achar).

-- Rótulos de tamanho na tabela centros (ex.: "Cento 100" → "Pacote 100")
update public.centros
   set label = regexp_replace(label, 'Cento', 'Pacote', 'gi')
 where label ~* 'cento';

-- Nome de exibição da categoria (ex.: "Centos" → "Pacotes")
update public.categorias
   set nome = regexp_replace(nome, 'Centos?', 'Pacotes', 'gi')
 where id = 'centros' and nome ~* 'centos?';

-- Textos de pedidos já salvos (itens, ex.: "1x Hambúrguer — Cento 100")
update public.pedidos
   set itens = regexp_replace(itens, 'Cento', 'Pacote', 'gi')
 where itens ~* 'cento';

-- ============================================================================
-- FIM — Checklist pós-execução:
--   ✓ Recarregue o painel (Ctrl+Shift+R).
--   ✓ Crie o admin em Authentication → Users e insira o UUID na tabela admins.
--   ✓ Teste o login do cliente (primeiro nome + WhatsApp).
--   ✓ Confira a Edge Function "loop-api" para o PIX automático.
--   ✓ Todo texto "Cento"/"Centos" já existente no banco foi renomeado para
--     "Pacote"/"Pacotes" automaticamente pela seção 15 acima.
-- ============================================================================
