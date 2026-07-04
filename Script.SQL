-- ============================================================================
-- PETIT BUFFET PREMIUM — SCRIPT SQL ÚNICO E UNIFICADO (Supabase)
-- Projeto: ejdboszoswqvgsjsrcmf
-- ============================================================================
-- Este é O ÚNICO arquivo SQL do projeto — junta tudo que existia espalhado:
--   • Todo o site (catálogo, carrinho, checkout, pedidos, admin, PIX, sabores,
--     venda por unidade, desconto de combo, separação Evento x Lanche).
--   • A notificação automática do Telegram a cada pedido novo (seção 20).
-- Não precisa mais rodar nenhum outro script — só este.
--
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
--   • Venda por unidade, desconto de combo, sabores administráveis e a
--     separação Evento x Lanche (carrinho, pagamento e pedidos).
--   • NOVO: notificação automática no Telegram a cada pedido novo — sem
--     depender de Edge Function, o próprio banco monta a mensagem e manda
--     direto (seção 20, no fim do arquivo).
--
-- COMO RODAR:
--   Supabase → SQL Editor → New query → cole TUDO → Run.
--   100% idempotente: pode rodar várias vezes, não apaga nem duplica nada.
--
-- DEPOIS DE RODAR:
--   1) Authentication → Users → crie o usuário admin (email + senha).
--   2) Copie o UUID e rode:  insert into public.admins (user_id) values ('UUID');
--   3) PIX: verifique a Edge Function "loop-api" e o secret do Mercado Pago.
--   4) Telegram: a notificação já sai funcionando sozinha depois de rodar
--      este script — não precisa configurar mais nada.
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
-- 16) VENDA POR UNIDADE + DESCONTO DE COMBO ADMINISTRÁVEL
-- ============================================================================
-- Objetivo: permitir comprar Empadas/Sanduíches por unidade avulsa, além dos
-- pacotes/combos já existentes — sem remover nada, sem quebrar produtos que
-- só vendem em combo (hambúrguer, pizza, etc. continuam exatamente iguais).
--
-- Modelo de dados:
--   • produtos.preco_unitario      → preço de 1 unidade avulsa (só relevante
--                                    quando venda_unitaria_ativa = true)
--   • produtos.venda_unitaria_ativa→ liga/desliga a venda por unidade deste
--                                    produto (checkbox no admin)
--   • produtos.unidade_minima/     → limites de quantidade na compra avulsa
--     unidade_maxima
--   • produtos.tipo_produto        → classifica o produto: 'combo' (só
--                                    pacotes, como hoje), 'unidade' (só
--                                    avulso) ou 'hibrido' (os dois — o caso
--                                    de Empada/Sanduíche)
--   • centros.desconto_combo       → quanto (em R$) aquele combo economiza
--                                    em relação a comprar as mesmas unidades
--                                    avulsas. O preço final do combo
--                                    continua sendo centros.preco (não muda
--                                    nada do que já existe) — este campo é
--                                    só para o site MOSTRAR a economia
--                                    ("De: R$80 / Por: R$71 / Economize R$9").
--   • centros.destaque             → admin marca manualmente qual combo é o
--                                    "Mais vendido" (evita ter que calcular
--                                    isso a partir do histórico de pedidos
--                                    toda vez que a página carrega).
--
-- Nada disso quebra produtos existentes: os defaults abaixo preservam 100%
-- do comportamento atual (venda_unitaria_ativa=false, tipo_produto='combo',
-- desconto_combo=0, destaque=false) até o admin ativar explicitamente.
-- ============================================================================

alter table public.produtos add column if not exists preco_unitario numeric;
alter table public.produtos add column if not exists venda_unitaria_ativa boolean not null default false;
alter table public.produtos add column if not exists unidade_minima integer not null default 1;
alter table public.produtos add column if not exists unidade_maxima integer not null default 100;
alter table public.produtos add column if not exists tipo_produto text not null default 'combo';

alter table public.produtos drop constraint if exists produtos_tipo_produto_check;
alter table public.produtos add constraint produtos_tipo_produto_check
  check (tipo_produto in ('combo','unidade','hibrido'));

alter table public.produtos drop constraint if exists produtos_unidade_min_max_check;
alter table public.produtos add constraint produtos_unidade_min_max_check
  check (unidade_maxima >= unidade_minima);

alter table public.centros add column if not exists desconto_combo numeric not null default 0;
alter table public.centros add column if not exists destaque boolean not null default false;

-- Índice parcial: útil para uma futura "vitrine de compra por unidade" sem
-- varrer a tabela toda (só indexa quem realmente vende por unidade).
create index if not exists idx_produtos_venda_unitaria
  on public.produtos(venda_unitaria_ativa) where venda_unitaria_ativa = true;

-- Habilita a venda por unidade especificamente para Empadas e Sanduíches
-- (os dois produtos pedidos), com um preço unitário inicial de referência —
-- ajuste depois pelo painel administrativo quando quiser.
update public.produtos
   set venda_unitaria_ativa = true,
       tipo_produto = 'hibrido',
       preco_unitario = coalesce(preco_unitario, case id when 'empada' then 5.00 when 'sanduiche' then 8.00 end),
       unidade_minima = 1,
       unidade_maxima = 100
 where id in ('empada','sanduiche');

-- ============================================================================
-- 17) PEDIDOS — colunas para guardar o tipo de compra por item (auditoria)
-- ============================================================================
-- centro_detalhes (jsonb) já guarda um array com um objeto por item do
-- carrinho. A partir de agora, cada objeto desse array passa a incluir:
--   tipo_compra: "combo" | "unidade"
--   desconto_aplicado: valor em R$ economizado (0 para compra avulsa)
-- Isso é feito só no lado da aplicação (index.html) — nenhuma coluna nova é
-- necessária aqui, porque centro_detalhes já é um jsonb flexível. Só
-- documentando o novo formato para referência:
--
-- exemplo (combo):  {"produto":"empada","centro":"m","label":"Pacote 60",
--                     "tipo_compra":"combo","qtdCentros":1,
--                     "precoUnitCentro":270,"desconto_aplicado":30,"subtotal":270}
-- exemplo (unidade):{"produto":"empada","centro":null,"label":"5 unidades avulsas",
--                     "tipo_compra":"unidade","qtdCentros":5,
--                     "precoUnitCentro":5,"desconto_aplicado":0,"subtotal":25}

-- ============================================================================
-- 18) SABORES — administráveis pelo painel (sem mexer em código)
-- ============================================================================
-- Antes, os sabores de Empada e Sanduíche Natural ficavam fixos no HTML.
-- Agora viram uma tabela igual a "centros" (mesmo padrão: produto_id + um id
-- próprio do sabor). Se a tabela estiver vazia para um produto, o site cai
-- de volta na lista fixa do HTML como rede de segurança — não quebra nada.
create table if not exists public.sabores (
  produto_id text    not null references public.produtos(id) on delete cascade,
  sabor_id   text    not null,
  nome       text    not null,
  ordem      integer not null default 0,
  ativo      boolean not null default true,
  primary key (produto_id, sabor_id)
);
create index if not exists idx_sabores_produto on public.sabores(produto_id) where ativo = true;

alter table public.sabores enable row level security;

drop policy if exists "sabores_leitura_publica" on public.sabores;
drop policy if exists "sabores_admin_escreve"   on public.sabores;
create policy "sabores_leitura_publica" on public.sabores for select using (true);
create policy "sabores_admin_escreve"   on public.sabores for all
  using (public.is_admin()) with check (public.is_admin());

-- Semente: os sabores que já existiam fixos no site, para o admin já ver e
-- poder editar/remover pelo painel em vez de partir de uma lista vazia.
insert into public.sabores (produto_id, sabor_id, nome, ordem) values
  ('sanduiche', 'atum',    'Atum',    1),
  ('sanduiche', 'frango',  'Frango',  2),
  ('empada',    'frango',  'Frango',  1),
  ('empada',    'camarao', 'Camarão', 2),
  ('empada',    'palmito', 'Palmito', 3),
  ('empada',    'queijo',  'Queijo',  4)
on conflict (produto_id, sabor_id) do nothing;

-- ============================================================================
-- 19) SEPARAÇÃO EVENTO x LANCHE — carrinho, pagamento e pedidos
-- ============================================================================
-- ATENÇÃO SOBRE NOMENCLATURA: a coluna produtos.tipo_produto JÁ EXISTE (seção
-- 16) e significa 'combo' | 'unidade' | 'hibrido' — é sobre COMO o produto é
-- vendido (por pacote, por unidade, ou os dois). Isso é uma coisa diferente
-- do que esta seção precisa, que é classificar o produto entre "evento" e
-- "lanche" (o QUE o produto é, pra fins de carrinho/pagamento). Por isso a
-- coluna nova aqui chama `categoria_compra`, não `tipo_produto` — evita
-- colidir com o campo que já existe e já está em produção.
--
-- Regra: Lanches (Empadas, Sanduíche Natural) não podem ser comprados
-- junto com produtos de Evento (Pacotes/combos) no mesmo pedido, e pagam
-- 100% na hora, sem entrada/saldo. Eventos continuam com 50%+50% igual hoje.
alter table public.produtos add column if not exists categoria_compra text not null default 'evento';
alter table public.produtos drop constraint if exists produtos_categoria_compra_check;
alter table public.produtos add constraint produtos_categoria_compra_check
  check (categoria_compra in ('evento','lanche'));

-- Classifica automaticamente os produtos já cadastrados: tudo que está na
-- categoria "lanches" vira categoria_compra='lanche'; o resto (Pacotes,
-- combos, hambúrguer etc.) permanece/vira 'evento'. Não perde nenhum dado —
-- só preenche a classificação nos registros que já existem.
update public.produtos set categoria_compra = 'lanche' where categoria_id = 'lanches';
update public.produtos set categoria_compra = 'evento' where categoria_id is distinct from 'lanches';

create index if not exists idx_produtos_categoria_compra on public.produtos(categoria_compra);

-- Pedidos passam a guardar qual categoria de compra e qual regra de
-- pagamento foram aplicadas — histórico fica auditável mesmo se as regras
-- mudarem no futuro (o pedido salvo não muda retroativamente).
alter table public.pedidos add column if not exists categoria_compra text;
alter table public.pedidos add column if not exists regra_pagamento text;



-- ============================================================================
-- 20) NOTIFICAÇÃO TELEGRAM — dispara sozinho a cada pedido novo
-- ============================================================================
-- O banco monta a mensagem e manda direto pro Telegram (sem Edge Function).
-- Mensagem final, exatamente como pedido:
--   📦 Novo Pedido Recebido 🎉
--   Pedido: #PB-20260704-6ZN3
--   Cliente: Filipe
--   Telefone: (68) 97400-5458
--   Total: R$ 1246,00
--   Itens:
--   • 1x Hambúrguer — Pacote 100
--   ...
--   Pagamento: PIX
--   Data do evento: 17/05 às 12:00
--   Endereço: Rua Princesinha, 246, Belo Jardim 1
--   Verificar pagamento de R$ 623,00
--   💬 Falar com Filipe no WhatsApp (link tocável)

create extension if not exists pg_net;

-- ----------------------------------------------------------------------------
-- Funções auxiliares (formatação — mesma lógica que já validamos antes)
-- ----------------------------------------------------------------------------

-- Escapa só o necessário pro modo HTML do Telegram (nomes/endereços com
-- ponto, hífen, "&", "<" etc. não quebram a formatação da mensagem).
create or replace function public.tg_escape_html(txt text)
returns text language sql immutable as $$
  select replace(replace(replace(coalesce(txt, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

-- Só os dígitos do telefone, já removendo o "+55" se veio junto por engano
-- (autopreenchimento do navegador/Google).
create or replace function public.tg_telefone_digitos(tel text)
returns text language plpgsql immutable as $$
declare d text;
begin
  d := regexp_replace(coalesce(tel, ''), '\D', '', 'g');
  if length(d) > 11 and left(d, 2) = '55' then d := substring(d from 3); end if;
  return d;
end;
$$;

-- Telefone formatado bonito: (68) 97400-5458 (celular) ou (68) 3221-1234 (fixo).
create or replace function public.tg_formatar_telefone(tel text)
returns text language plpgsql immutable as $$
declare d text;
begin
  d := public.tg_telefone_digitos(tel);
  if length(d) < 10 then return coalesce(nullif(tel, ''), 'Não informado'); end if;
  if length(d) = 11 then
    return '(' || substring(d from 1 for 2) || ') ' || substring(d from 3 for 5) || '-' || substring(d from 8);
  end if;
  return '(' || substring(d from 1 for 2) || ') ' || substring(d from 3 for 4) || '-' || substring(d from 7);
end;
$$;

-- "R$ 1246,00" — sem separador de milhar, igual ao site.
create or replace function public.tg_formatar_moeda(v numeric)
returns text language sql immutable as $$
  select 'R$ ' || replace(to_char(coalesce(v, 0)::numeric, 'FM999999999990.00'), '.', ',');
$$;

-- Transforma "1x Produto — Pacote X (R$ 999,00) | 2x Outro (R$ 85,00)" em
-- linhas com bullet, sem o preço (o total já aparece destacado em separado).
create or replace function public.tg_formatar_itens(itens_str text)
returns text language plpgsql immutable as $$
declare
  resultado text;
begin
  select string_agg(
           '• ' || public.tg_escape_html(trim(regexp_replace(item, '\s*\(R\$\s?[\d.,]+\)\s*$', ''))),
           E'\n'
         )
    into resultado
    from regexp_split_to_table(coalesce(itens_str, ''), '\s*\|\s*') as item
   where trim(item) <> '';
  return coalesce(resultado, '• Nenhum item informado');
end;
$$;

-- ----------------------------------------------------------------------------
-- Função principal: monta a mensagem e manda pro Telegram
-- ----------------------------------------------------------------------------
create or replace function public.notificar_telegram_pedido()
returns trigger
language plpgsql
security definer
as $$
declare
  v_emoji     text;
  v_wpp_link  text := '';
  v_tel_dig   text;
  v_wpp_texto text;
  v_msg       text;
begin
  v_emoji := case NEW.categoria_compra
    when 'evento' then ' 🎉'
    when 'lanche' then ' 🥪'
    else ''
  end;

  v_tel_dig := public.tg_telefone_digitos(NEW.telefone);
  if length(v_tel_dig) >= 10 then
    v_wpp_texto := 'Ol%C3%A1%20' || replace(public.tg_escape_html(coalesce(NEW.nome, '')), ' ', '%20')
                 || '%21%20Vi%20seu%20pedido%20%23' || public.tg_escape_html(NEW.pedido)
                 || '%20aqui%20na%20Petit%20Buffet.';
    v_wpp_link := E'\n💬 <a href="https://wa.me/55' || v_tel_dig || '?text=' || v_wpp_texto || '">Falar com '
                || coalesce(nullif(public.tg_escape_html(NEW.nome), ''), 'o cliente') || ' no WhatsApp</a>';
  end if;

  v_msg := '📦 <b>Novo Pedido Recebido</b>' || v_emoji || E'\n'
        || '<b>Pedido:</b> #' || public.tg_escape_html(NEW.pedido) || E'\n'
        || '<b>Cliente:</b> ' || coalesce(nullif(public.tg_escape_html(NEW.nome), ''), 'Não informado') || E'\n'
        || '<b>Telefone:</b> ' || public.tg_formatar_telefone(NEW.telefone) || E'\n'
        || '<b>Total:</b> ' || public.tg_formatar_moeda(NEW.total) || E'\n'
        || '<b>Itens:</b>' || E'\n' || public.tg_formatar_itens(NEW.itens) || E'\n'
        || '<b>Pagamento:</b> ' || coalesce(nullif(public.tg_escape_html(NEW.forma_pagamento), ''), 'Não informado');

  if NEW.data_agendada is not null and NEW.data_agendada <> '' then
    v_msg := v_msg || E'\n<b>' || coalesce(nullif(public.tg_escape_html(NEW.tipo_agendamento), ''), 'Data')
           || ':</b> ' || public.tg_escape_html(NEW.data_agendada) || ' às ' || public.tg_escape_html(coalesce(NEW.hora_agendada, ''));
  end if;

  if NEW.endereco is not null and NEW.endereco <> '' then
    v_msg := v_msg || E'\n<b>Endereço:</b> ' || public.tg_escape_html(NEW.endereco);
  end if;

  if NEW.sinal is not null and NEW.sinal > 0 then
    v_msg := v_msg || E'\nVerificar pagamento de ' || public.tg_formatar_moeda(NEW.sinal);
  end if;

  v_msg := v_msg || v_wpp_link;

  perform net.http_post(
    url := 'https://api.telegram.org/bot8530482063:AAER52_HJrsnExT7ipVdsP9K25ReaN7YzM4/sendMessage',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object(
      'chat_id', '7694564020',
      'text', v_msg,
      'parse_mode', 'HTML'
    ),
    timeout_milliseconds := 5000
  );

  return NEW;
end;
$$;

-- ----------------------------------------------------------------------------
-- O gatilho em si
-- ----------------------------------------------------------------------------
drop trigger if exists trg_pedidos_notificar_telegram on public.pedidos;
create trigger trg_pedidos_notificar_telegram
  after insert on public.pedidos
  for each row execute function public.notificar_telegram_pedido();

-- ============================================================================
-- FIM — Checklist pós-execução:
--   ✓ Recarregue o painel (Ctrl+Shift+R).
--   ✓ Crie o admin em Authentication → Users e insira o UUID na tabela admins.
--   ✓ Teste o login do cliente (primeiro nome + WhatsApp).
--   ✓ Confira a Edge Function "loop-api" para o PIX automático.
--   ✓ Todo texto "Cento"/"Centos" já existente no banco foi renomeado para
--     "Pacote"/"Pacotes" automaticamente pela seção 15.
--   ✓ Empada e Sanduíche Natural já saem com venda por unidade ATIVADA e um
--     preço unitário de referência (R$ 5,00 / R$ 8,00) — ajuste no painel
--     em Catálogo → editar produto → "Venda por unidade".
--   ✓ Sabores de Empada e Sanduíche já migrados para a tabela e editáveis em
--     Catálogo → editar produto → "Sabores".
--   ✓ Configure o desconto de cada combo em Catálogo → editar produto →
--     Preços & Pacotes → campo "Desconto do combo".
--   ✓ Produtos já classificados automaticamente em "Evento"/"Lanche" — ajuste
--     em Catálogo → editar produto → "Tipo do Produto (Evento/Lanche)".
--   ✓ Notificação do Telegram já ativa — teste inserindo um pedido em
--     Table Editor → pedidos → Insert row → Save. Chega em segundos.
--   ✓ A Edge Function "notify-telegram-order" (se ainda existir) não é mais
--     usada — pode ignorá-la ou apagá-la, sem efeito no funcionamento.
-- ============================================================================Olá Filipe! Vi seu pedido #PB-20260704-X510 aqui na Petit Buffet.
