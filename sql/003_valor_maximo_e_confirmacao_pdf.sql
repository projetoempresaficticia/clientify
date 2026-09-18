-- 003_valor_maximo_e_confirmacao_pdf.sql — duas correções pedidas pelo
-- Germano:
--
-- 1. O valor de cada pedido deixa de vir de uma "média" abstrata — passa
--    a ser sempre a soma real de produtos do catálogo (preço ×
--    quantidade), escolhidos ao acaso mas nunca ultrapassando um valor
--    MÁXIMO estipulado (rename valor_medio → valor_maximo em toda a
--    parte: tabela, RPCs, frontend). O nº de pedidos por ciclo continua
--    proporcional ao custo da empresa, só que agora dividido pelo teto,
--    não pela média.
--
-- 2. A confirmação de compra em PDF passa a ficar mesmo anexada à
--    mensagem do Correio (AeroMail já tem bucket 'correio' +
--    correio_anexos + UI para mostrar anexos — não precisa de nada
--    novo lá). Como o PDF só pode ser gerado num browser (jsPDF), não
--    existe no momento em que o pedido é criado (nem manual nem pelo
--    cron, que não tem sessão nenhuma) — fica pronto e anexado da
--    primeira vez que alguém o abre no Clientify, ficando guardado a
--    sério no Storage a partir daí (não é gerado de novo a cada
--    clique). correio_enviar() não serve aqui: exige um destinatário
--    PESSOA (não empresa) e usa fn_minha_cedula() como remetente fixo
--    — os pedidos vão para a cédula da EMPRESA, remetidos por
--    "Clientify". Por isso o anexo é inserido diretamente em
--    correio_anexos, mesmo padrão de correio_enviar por dentro.

-- ── liga cada pedido à mensagem de correio que o entregou ───────────
alter table public.pedidos add column correio_id uuid references public.correio(id);
alter table public.pedidos add column confirmacao_pdf_caminho text;

-- ── rename valor_medio -> valor_maximo em cli_agendamento ───────────
alter table public.cli_agendamento rename column valor_medio to valor_maximo;

-- ── cli_gerar_ciclo_interno — reescrita: valor máximo + grava correio_id ─
-- (o nome do parâmetro muda de p_valor_medio para p_valor_maximo — o
-- Postgres não deixa `create or replace` renomear parâmetro, precisa
-- de dropar primeiro)
drop function if exists public.cli_gerar_ciclo_interno(text, bigint);
drop function if exists public.cli_gerar_ciclo(text, bigint);
drop function if exists public.cli_definir_agendamento(text, bigint, int, boolean);

create or replace function public.cli_gerar_ciclo_interno(p_ciclo text, p_valor_maximo bigint)
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
  v_correio_id uuid;
  v_n_itens int;
  r_prod record;
  v_total bigint;
  v_orcamento bigint;
  v_primeiro boolean;
  v_qtd_max int;
  v_qtd int;
  v_n_pedidos int := 0;
  v_n_empresas int := 0;
begin
  if p_valor_maximo is null or p_valor_maximo <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'Valor máximo do pedido tem de ser positivo.');
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

    v_npedidos := greatest(1, ceil(v_custo::numeric / p_valor_maximo)) + v_bonus;
    v_n_empresas := v_n_empresas + 1;

    for i in 1..v_npedidos loop
      v_pid := gen_random_uuid();
      v_total := 0;
      v_orcamento := p_valor_maximo;
      v_primeiro := true;
      v_n_itens := 1 + floor(random() * 3)::int; -- até 3 produtos distintos

      insert into public.pedidos(id, empresa_cedula, cliente_nome, ciclo, estado, valor_total)
      values (v_pid, r_emp.cedula, 'Cliente ' || i, p_ciclo, 'enviado', 0);

      for r_prod in
        select * from public.produtos where empresa_cedula = r_emp.cedula
         order by random() limit v_n_itens
      loop
        if v_primeiro then
          -- garante pelo menos 1 item, mesmo que o preço isolado do
          -- produto já ultrapasse o máximo estipulado
          v_qtd_max := greatest(1, least(r_prod.qtd_dia, (v_orcamento / r_prod.preco_venda)::int));
          v_primeiro := false;
        else
          if v_orcamento < r_prod.preco_venda then continue; end if; -- não cabe mais nada
          v_qtd_max := least(r_prod.qtd_dia, (v_orcamento / r_prod.preco_venda)::int);
        end if;

        v_qtd := 1 + floor(random() * v_qtd_max)::int;
        insert into public.pedido_itens(pedido_id, produto_id, quantidade, preco_unit)
        values (v_pid, r_prod.id, v_qtd, r_prod.preco_venda);
        v_total := v_total + r_prod.preco_venda * v_qtd;
        v_orcamento := v_orcamento - r_prod.preco_venda * v_qtd;
        exit when v_orcamento <= 0;
      end loop;

      update public.pedidos set valor_total = v_total where id = v_pid;

      insert into public.correio(de_cedula, para_cedula, assunto, corpo)
      values (v_clientify, r_emp.cedula, 'Novo pedido — ' || p_ciclo,
              'Pedido de ' || (select cliente_nome from public.pedidos where id = v_pid)
                || '. Valor: ' || to_char(v_total / 100.0, 'FM999999990.00') || ' P$.')
      returning id into v_correio_id;
      update public.pedidos set correio_id = v_correio_id where id = v_pid;

      v_n_pedidos := v_n_pedidos + 1;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'pedidos_gerados', v_n_pedidos, 'empresas_atendidas', v_n_empresas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao gerar ciclo: ' || sqlerrm);
end;
$function$;

-- ── wrapper público — troca só o nome do parâmetro ───────────────────
create or replace function public.cli_gerar_ciclo(p_ciclo text, p_valor_maximo bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.fn_e_professor() then
    return jsonb_build_object('ok', false, 'erro', 'Sem permissão.');
  end if;
  return public.cli_gerar_ciclo_interno(p_ciclo, p_valor_maximo);
end;
$function$;

-- (o drop apagou os grants — reconceder, mesmo acesso de sempre)
revoke all on function public.cli_gerar_ciclo_interno(text, bigint) from public, anon, authenticated;
revoke all on function public.cli_gerar_ciclo(text, bigint) from public, anon, authenticated;
grant execute on function public.cli_gerar_ciclo(text, bigint) to authenticated;

-- ── agendamento: mesma troca de nome ─────────────────────────────────
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
    'valor_maximo', v_cfg.valor_maximo, 'ativo', v_cfg.ativo,
    'ultima_execucao', v_cfg.ultima_execucao,
    'proxima_prevista', case when v_cfg.ativo
      then coalesce(v_cfg.ultima_execucao, v_cfg.atualizado_em) + (v_cfg.intervalo_dias || ' days')::interval
      else null end
  ));
end;
$function$;

create or replace function public.cli_definir_agendamento(
  p_frequencia text, p_valor_maximo bigint default 5000, p_intervalo_dias int default null, p_ativo boolean default true)
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
  if p_valor_maximo is null or p_valor_maximo <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'Valor máximo do pedido tem de ser positivo.');
  end if;

  update public.cli_agendamento
     set frequencia = p_frequencia, intervalo_dias = v_intervalo, valor_maximo = p_valor_maximo,
         ativo = coalesce(p_ativo, true), atualizado_em = now(), atualizado_por = auth.uid()
   where id = 1;

  return public.cli_agendamento_atual();
end;
$function$;

revoke all on function public.cli_definir_agendamento(text, bigint, int, boolean) from public, anon, authenticated;
grant execute on function public.cli_definir_agendamento(text, bigint, int, boolean) to authenticated;

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
  v_res := public.cli_gerar_ciclo_interno(v_ciclo, v_cfg.valor_maximo);

  update public.cli_agendamento set ultima_execucao = now() where id = 1;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'executado', true, 'ciclo', v_ciclo, 'resultado', v_res));
end;
$function$;

-- ── confirmação de compra: liga um PDF real, já carregado no Storage
-- (bucket 'correio', pasta da pessoa que gerou), à mensagem que
-- entregou o pedido. A empresa só pode fazer isto ao seu próprio
-- pedido; o caminho tem de ser mesmo um ficheiro que acabou de
-- carregar (confere em storage.objects, mesmo padrão de
-- correio_enviar). Idempotente: se já há confirmação, devolve a
-- existente sem duplicar o anexo. ──────────────────────────────────
create or replace function public.cli_anexar_confirmacao_pdf(p_pedido_id uuid, p_caminho text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_pedido record; v_obj record; v_de_pessoa text := public.fn_minha_cedula();
begin
  if v_de_pessoa is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select * into v_pedido from public.pedidos where id = p_pedido_id;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Pedido não encontrado.');
  end if;
  if v_pedido.empresa_cedula is distinct from public.fn_minha_empresa_cedula() then
    return jsonb_build_object('ok', false, 'erro', 'Este pedido não é da sua empresa.');
  end if;

  if v_pedido.confirmacao_pdf_caminho is not null then
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('caminho', v_pedido.confirmacao_pdf_caminho, 'novo', false));
  end if;
  if v_pedido.correio_id is null then
    return jsonb_build_object('ok', false, 'erro', 'Este pedido não tem mensagem de correio associada.');
  end if;
  if split_part(p_caminho, '/', 1) <> v_de_pessoa then
    return jsonb_build_object('ok', false, 'erro', 'Caminho fora da sua pasta.');
  end if;

  select name, metadata into v_obj from storage.objects
   where bucket_id = 'correio' and name = p_caminho;
  if v_obj.name is null then
    return jsonb_build_object('ok', false, 'erro', 'Ficheiro não encontrado — confirme que o carregamento terminou.');
  end if;

  insert into public.correio_anexos(mensagem_id, caminho, nome, tamanho, tipo, inline)
  values (v_pedido.correio_id, p_caminho, regexp_replace(p_caminho, '^.*/', ''),
          coalesce((v_obj.metadata->>'size')::bigint, 0), v_obj.metadata->>'mimetype', false);

  update public.pedidos set confirmacao_pdf_caminho = p_caminho where id = p_pedido_id;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('caminho', p_caminho, 'novo', true));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao anexar confirmação: ' || sqlerrm);
end;
$function$;

revoke all on function public.cli_anexar_confirmacao_pdf(uuid, text) from public, anon;
grant execute on function public.cli_anexar_confirmacao_pdf(uuid, text) to authenticated;

-- ── cli_meus_pedidos passa a devolver a cédula da pessoa (para montar
-- o caminho do upload) e o caminho da confirmação já gerada ─────────
create or replace function public.cli_meus_pedidos()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_empresa text := public.fn_minha_empresa_cedula(); v_linhas jsonb;
begin
  if v_empresa is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem empresa associada.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'pedido_id', p.id, 'cliente_nome', p.cliente_nome, 'ciclo', p.ciclo,
           'valor_total', p.valor_total, 'estado', p.estado,
           'fatura_doc_id', p.fatura_doc_id, 'criada_em', p.criada_em,
           'confirmacao_pdf_caminho', p.confirmacao_pdf_caminho,
           'itens', (
             select coalesce(jsonb_agg(jsonb_build_object(
                      'produto', pr.nome, 'quantidade', pi.quantidade, 'preco_unit', pi.preco_unit
                    )), '[]'::jsonb)
             from public.pedido_itens pi join public.produtos pr on pr.id = pi.produto_id
             where pi.pedido_id = p.id
           )
         ) order by p.criada_em desc), '[]'::jsonb)
    into v_linhas
    from public.pedidos p
   where p.empresa_cedula = v_empresa;

  return jsonb_build_object('ok', true, 'dados', v_linhas);
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível listar os pedidos.');
end;
$function$;
