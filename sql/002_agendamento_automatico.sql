-- 002_agendamento_automatico.sql — a professora escolhe de quanto em
-- quanto tempo o ciclo de pedidos é gerado (diário/semanal/quinzenal/
-- mensal/personalizado), sem precisar de clicar em "Gerar ciclo" à mão.
-- Mesmo padrão já validado no EmDia (sql/004+005): tabela de
-- configuração de linha única + relógio diário do pg_cron que só age
-- quando o intervalo escolhido já passou desde a última vez.
--
-- cli_gerar_ciclo exige fn_e_professor() — certo para o botão manual do
-- professor.html, mas o pg_cron não tem sessão nenhuma (auth.uid() vem
-- NULL). Por isso o miolo passa a viver em cli_gerar_ciclo_interno
-- (sem gate, nunca exposto a anon/authenticated), e o nome público
-- continua a existir com o mesmo comportamento de sempre.
--
-- O ciclo automático chama-se pela data de emissão (YYYY-MM-DD), não
-- por um nome livre como os ciclos manuais — com cadência diária ou
-- semanal, duas gerações no mesmo "período" têm de ter ciclos
-- distintos, senão a segunda seria recusada pela idempotência de
-- cli_gerar_ciclo (um ciclo só pode ser gerado uma vez).

create table public.cli_agendamento (
  id smallint primary key default 1,
  frequencia text not null default 'semanal'
    check (frequencia in ('diario', 'semanal', 'quinzenal', 'mensal', 'personalizado')),
  intervalo_dias int not null default 7 check (intervalo_dias between 1 and 365),
  valor_medio bigint not null default 5000 check (valor_medio > 0),
  ativo boolean not null default true,
  ultima_execucao timestamptz,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid references auth.users(id),
  constraint cli_agendamento_singular check (id = 1)
);

alter table public.cli_agendamento enable row level security;
-- sem policies: linha única, acesso só pelas RPCs abaixo.

-- ultima_execucao = agora: já geraram ciclos de teste manualmente; o
-- relógio automático só conta a partir de hoje, para não repetir logo
-- a seguir a uma geração manual recente.
insert into public.cli_agendamento (id, frequencia, intervalo_dias, valor_medio, ativo, ultima_execucao)
values (1, 'semanal', 7, 5000, true, now());

-- ── miolo sem gate — o wrapper público e o cron chamam esta versão ──
create or replace function public.cli_gerar_ciclo_interno(p_ciclo text, p_valor_medio bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_clientify text;
  r_emp record;
  v_custo bigint;
  v_bonus int;
  v_npedidos int;
  i int;
  v_pid uuid;
  v_n_itens int;
  r_prod record;
  v_total bigint;
  v_qtd int;
  v_n_pedidos int := 0;
  v_n_empresas int := 0;
begin
  if p_valor_medio is null or p_valor_medio <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'Valor médio do pedido tem de ser positivo.');
  end if;
  if exists (select 1 from public.pedidos where ciclo = p_ciclo) then
    return jsonb_build_object('ok', false, 'erro', 'Ciclo já gerado: ' || p_ciclo);
  end if;

  select cedula into v_clientify from public.empresas where nome = 'Clientify';

  for r_emp in
    select cedula from public.empresas
     where estado = 'ativa' and cedula <> v_clientify
       and exists (select 1 from public.produtos where empresa_cedula = empresas.cedula)
  loop
    v_custo := public.fn_custo_base(r_emp.cedula);
    select count(*) into v_bonus
      from public.pedidos
     where empresa_cedula = r_emp.cedula and estado = 'concluído'
       and criada_em > now() - interval '30 days';
    v_bonus := v_bonus / 3;

    v_npedidos := greatest(1, ceil(v_custo::numeric / p_valor_medio)) + v_bonus;
    v_n_empresas := v_n_empresas + 1;

    for i in 1..v_npedidos loop
      v_pid := gen_random_uuid();
      v_total := 0;
      v_n_itens := 1 + floor(random() * 3)::int;

      insert into public.pedidos(id, empresa_cedula, cliente_nome, ciclo, estado, valor_total)
      values (v_pid, r_emp.cedula, 'Cliente ' || i, p_ciclo, 'enviado', 0);

      for r_prod in
        select * from public.produtos where empresa_cedula = r_emp.cedula
         order by random() limit v_n_itens
      loop
        v_qtd := 1 + floor(random() * greatest(1, r_prod.qtd_dia))::int;
        insert into public.pedido_itens(pedido_id, produto_id, quantidade, preco_unit)
        values (v_pid, r_prod.id, v_qtd, r_prod.preco_venda);
        v_total := v_total + r_prod.preco_venda * v_qtd;
      end loop;

      update public.pedidos set valor_total = v_total where id = v_pid;

      insert into public.correio(de_cedula, para_cedula, assunto, corpo)
      values (v_clientify, r_emp.cedula, 'Novo pedido — ' || p_ciclo,
              'Pedido de ' || (select cliente_nome from public.pedidos where id = v_pid)
                || '. Valor: ' || to_char(v_total / 100.0, 'FM999999990.00') || ' P$.');

      v_n_pedidos := v_n_pedidos + 1;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'pedidos_gerados', v_n_pedidos, 'empresas_atendidas', v_n_empresas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao gerar ciclo: ' || sqlerrm);
end;
$function$;

revoke all on function public.cli_gerar_ciclo_interno(text, bigint) from public, anon, authenticated;

-- ── wrapper público (professor.html) — mesma assinatura de sempre ──
create or replace function public.cli_gerar_ciclo(p_ciclo text, p_valor_medio bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.fn_e_professor() then
    return jsonb_build_object('ok', false, 'erro', 'Sem permissão.');
  end if;
  return public.cli_gerar_ciclo_interno(p_ciclo, p_valor_medio);
end;
$function$;

-- (grants já existiam deste de sql/001 — create or replace não os apaga)

-- ── leitura/escrita do agendamento (professor.html) ─────────────────
create or replace function public.cli_agendamento_atual()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_cfg public.cli_agendamento;
begin
  if not public.fn_e_professor() then
    return jsonb_build_object('ok', false, 'erro', 'Sem permissão.');
  end if;

  select * into v_cfg from public.cli_agendamento where id = 1;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'frequencia', v_cfg.frequencia, 'intervalo_dias', v_cfg.intervalo_dias,
    'valor_medio', v_cfg.valor_medio, 'ativo', v_cfg.ativo,
    'ultima_execucao', v_cfg.ultima_execucao,
    'proxima_prevista', case when v_cfg.ativo
      then coalesce(v_cfg.ultima_execucao, v_cfg.atualizado_em) + (v_cfg.intervalo_dias || ' days')::interval
      else null end
  ));
end;
$function$;

revoke all on function public.cli_agendamento_atual() from public, anon;
grant execute on function public.cli_agendamento_atual() to authenticated;

create or replace function public.cli_definir_agendamento(
  p_frequencia text, p_valor_medio bigint default 5000, p_intervalo_dias int default null, p_ativo boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_intervalo int;
begin
  if not public.fn_e_professor() then
    return jsonb_build_object('ok', false, 'erro', 'Sem permissão.');
  end if;

  if p_frequencia not in ('diario', 'semanal', 'quinzenal', 'mensal', 'personalizado') then
    return jsonb_build_object('ok', false, 'erro', 'Frequência inválida.');
  end if;

  v_intervalo := case p_frequencia
    when 'diario' then 1
    when 'semanal' then 7
    when 'quinzenal' then 15
    when 'mensal' then 30
    when 'personalizado' then p_intervalo_dias
  end;

  if v_intervalo is null or v_intervalo < 1 or v_intervalo > 365 then
    return jsonb_build_object('ok', false, 'erro', 'Intervalo em dias inválido (1 a 365).');
  end if;
  if p_valor_medio is null or p_valor_medio <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'Valor médio do pedido tem de ser positivo.');
  end if;

  update public.cli_agendamento
     set frequencia = p_frequencia, intervalo_dias = v_intervalo, valor_medio = p_valor_medio,
         ativo = coalesce(p_ativo, true), atualizado_em = now(), atualizado_por = auth.uid()
   where id = 1;

  return public.cli_agendamento_atual();
end;
$function$;

revoke all on function public.cli_definir_agendamento(text, bigint, int, boolean) from public, anon, authenticated;
grant execute on function public.cli_definir_agendamento(text, bigint, int, boolean) to authenticated;

-- ── o relógio diário: só gera quando o intervalo já passou ──────────
create or replace function public.cli_cron_gerar_agendado()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_cfg public.cli_agendamento; v_ciclo text; v_res jsonb;
begin
  select * into v_cfg from public.cli_agendamento where id = 1;
  if not found or not v_cfg.ativo then
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('executado', false, 'motivo', 'agendamento inativo'));
  end if;

  if v_cfg.ultima_execucao is not null
     and v_cfg.ultima_execucao > now() - (v_cfg.intervalo_dias || ' days')::interval then
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('executado', false, 'motivo', 'ainda não venceu o intervalo'));
  end if;

  v_ciclo := to_char(now(), 'YYYY-MM-DD');
  v_res := public.cli_gerar_ciclo_interno(v_ciclo, v_cfg.valor_medio);

  update public.cli_agendamento set ultima_execucao = now() where id = 1;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'executado', true, 'ciclo', v_ciclo, 'resultado', v_res));
end;
$function$;

revoke all on function public.cli_cron_gerar_agendado() from public, anon, authenticated;

-- ── o relógio ─────────────────────────────────────────────────────────
select cron.unschedule(jobid) from cron.job where jobname = 'clientify-verificar-gerar';

select cron.schedule('clientify-verificar-gerar', '0 9 * * *',
  $$select public.cli_cron_gerar_agendado();$$);
