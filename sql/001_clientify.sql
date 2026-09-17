-- 001_clientify.sql — o gerador de clientes externos: a única fonte de
-- dinheiro NOVO no ecossistema. cli_gerar_ciclo já existia no banco mas
-- nunca tinha corrido com sucesso — cópia da skill nunca adaptada, com
-- bugs reais encontrados por leitura direta (não assumidos): sem gate
-- de permissão, sem idempotência, remetente do correio era a string
-- 'GERADOR' (não uma cédula real), só escolhia 1 produto por pedido
-- (a skill pede 1–3), sem tratar empresa sem catálogo, sem bónus por
-- mérito. cli_aceitar/cli_emitir_fatura/cli_liberar/cli_concluir nunca
-- tinham sido escritas.

-- ── a empresa "Clientify" — remetente real do correio, mesmo padrão
-- já usado para "EmDia" no pp-utilities. Não participa do fluxo de
-- dinheiro (a injeção usa banco_creditar_inicial_interno, sem origem).
do $$
declare v_cedula text;
begin
  if not exists (select 1 from public.empresas where nome = 'Clientify') then
    v_cedula := public.fn_proxima_cedula('EP');
    insert into public.empresas(cedula, nome, nif_ficticio, email_empresa, regiao, setor, estado)
    values (v_cedula, 'Clientify', regexp_replace(v_cedula, '\D', '', 'g'),
            'clientify@prepara.pt', 'Lisboa', 'clientes', 'ativa');
    perform public.banco_criar_conta_interna(v_cedula, null);
  end if;
end $$;

-- ── RLS de pedidos/pedido_itens (tabelas já existiam, vazias, sem
-- policies — sql/references/rls-clientes.md documentava fn_e_admin(),
-- que não existe; troca por fn_e_professor()) ────────────────────────
create policy "empresa vê os seus pedidos"
  on public.pedidos for select
  using (empresa_cedula = fn_minha_empresa_cedula());

create policy "admin vê pedidos"
  on public.pedidos for select
  using (fn_e_professor());

create policy "ver itens dos meus pedidos"
  on public.pedido_itens for select
  using (exists (
    select 1 from public.pedidos p
    where p.id = pedido_itens.pedido_id
      and (p.empresa_cedula = fn_minha_empresa_cedula() or fn_e_professor())
  ));

-- ── cli_gerar_ciclo — reescrita ──────────────────────────────────────
create or replace function public.cli_gerar_ciclo(p_ciclo text, p_valor_medio bigint)
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
  if not public.fn_e_professor() then
    return jsonb_build_object('ok', false, 'erro', 'Sem permissão.');
  end if;
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
    -- bónus modesto: +1 pedido por cada 3 concluídos nos últimos 30
    -- dias (mérito recente, sem depender de "ciclo anterior" — ciclo é
    -- texto livre, sem ordem garantida entre empresas).
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
      v_n_itens := 1 + floor(random() * 3)::int; -- 1 a 3 itens

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

revoke all on function public.cli_gerar_ciclo(text, bigint) from public, anon, authenticated;
grant execute on function public.cli_gerar_ciclo(text, bigint) to authenticated;

-- ── cli_aceitar ──────────────────────────────────────────────────────
create or replace function public.cli_aceitar(p_pedido_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_pedido record;
begin
  select * into v_pedido from public.pedidos where id = p_pedido_id;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Pedido não encontrado.');
  end if;
  if v_pedido.empresa_cedula is distinct from public.fn_minha_empresa_cedula() then
    return jsonb_build_object('ok', false, 'erro', 'Este pedido não é da sua empresa.');
  end if;
  if v_pedido.estado <> 'enviado' then
    return jsonb_build_object('ok', false, 'erro', 'Só se aceita um pedido no estado "enviado".');
  end if;

  update public.pedidos set estado = 'aceite' where id = p_pedido_id;
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('estado', 'aceite'));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao aceitar: ' || sqlerrm);
end;
$function$;

revoke all on function public.cli_aceitar(uuid) from public, anon;
grant execute on function public.cli_aceitar(uuid) to authenticated;

-- ── cli_emitir_fatura — liga um documento já criado e assinado no
-- Subsight ao pedido (não cria o documento; a skill já desenha assim) ─
create or replace function public.cli_emitir_fatura(p_pedido_id uuid, p_fatura_doc_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_pedido record; v_doc record;
begin
  select * into v_pedido from public.pedidos where id = p_pedido_id;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Pedido não encontrado.');
  end if;
  if v_pedido.empresa_cedula is distinct from public.fn_minha_empresa_cedula() then
    return jsonb_build_object('ok', false, 'erro', 'Este pedido não é da sua empresa.');
  end if;
  if v_pedido.estado <> 'aceite' then
    return jsonb_build_object('ok', false, 'erro', 'Só se liga a fatura a um pedido no estado "aceite".');
  end if;

  select * into v_doc from public.documentos where id = p_fatura_doc_id;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Documento não encontrado. Confira o ID copiado do Subsight.');
  end if;
  if not exists (
    select 1 from public.documento_slots
     where documento_id = p_fatura_doc_id and empresa_esperada = v_pedido.empresa_cedula
  ) then
    return jsonb_build_object('ok', false, 'erro', 'Este documento não está assinado pela sua empresa.');
  end if;

  update public.pedidos set estado = 'fatura_emitida', fatura_doc_id = p_fatura_doc_id where id = p_pedido_id;
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('estado', 'fatura_emitida'));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao ligar fatura: ' || sqlerrm);
end;
$function$;

revoke all on function public.cli_emitir_fatura(uuid, uuid) from public, anon;
grant execute on function public.cli_emitir_fatura(uuid, uuid) to authenticated;

-- ── cli_liberar — verifica a fatura assinada e só aí injeta dinheiro
-- novo (banco_creditar_inicial_interno, sql/0012 do prepacoin) ───────
create or replace function public.cli_liberar(p_pedido_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_pedido record; v_verif jsonb; v_credito jsonb;
begin
  select * into v_pedido from public.pedidos where id = p_pedido_id;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Pedido não encontrado.');
  end if;
  if v_pedido.empresa_cedula is distinct from public.fn_minha_empresa_cedula() then
    return jsonb_build_object('ok', false, 'erro', 'Este pedido não é da sua empresa.');
  end if;
  if v_pedido.estado <> 'fatura_emitida' then
    return jsonb_build_object('ok', false, 'erro', 'Só se confirma pagamento com a fatura já ligada.');
  end if;

  v_verif := public.ass_verificar(v_pedido.fatura_doc_id);
  if not (v_verif->>'ok')::boolean or not (v_verif->'dados'->>'valido')::boolean then
    return jsonb_build_object('ok', false, 'erro', 'A fatura ainda não está válida (falta assinatura ou anexo).');
  end if;

  v_credito := public.banco_creditar_inicial_interno(
    v_pedido.empresa_cedula, v_pedido.valor_total,
    'Pedido ' || v_pedido.cliente_nome || ' — ' || v_pedido.ciclo, 'venda_cliente');
  if not (v_credito->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'erro', 'Falha ao creditar: ' || (v_credito->>'erro'));
  end if;

  update public.pedidos
     set estado = 'pago', transacao_id = (v_credito->'dados'->>'id')::uuid
   where id = p_pedido_id;
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('estado', 'pago', 'saldo', v_credito->'dados'->>'saldo'));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao liberar: ' || sqlerrm);
end;
$function$;

revoke all on function public.cli_liberar(uuid) from public, anon, authenticated;
grant execute on function public.cli_liberar(uuid) to authenticated;

-- ── cli_concluir ─────────────────────────────────────────────────────
create or replace function public.cli_concluir(p_pedido_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_pedido record;
begin
  select * into v_pedido from public.pedidos where id = p_pedido_id;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Pedido não encontrado.');
  end if;
  if v_pedido.empresa_cedula is distinct from public.fn_minha_empresa_cedula() then
    return jsonb_build_object('ok', false, 'erro', 'Este pedido não é da sua empresa.');
  end if;
  if v_pedido.estado <> 'pago' then
    return jsonb_build_object('ok', false, 'erro', 'Só se conclui um pedido já pago.');
  end if;

  update public.pedidos set estado = 'concluído' where id = p_pedido_id;
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('estado', 'concluído'));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao concluir: ' || sqlerrm);
end;
$function$;

revoke all on function public.cli_concluir(uuid) from public, anon;
grant execute on function public.cli_concluir(uuid) to authenticated;

-- ── leitura: pedidos da empresa, com itens ──────────────────────────
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

revoke all on function public.cli_meus_pedidos() from public, anon;
grant execute on function public.cli_meus_pedidos() to authenticated;

-- ── leitura: resumo por ciclo/estado (painel da professora) ─────────
create or replace function public.cli_professor_resumo()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare v_linhas jsonb;
begin
  if not public.fn_e_professor() then
    return jsonb_build_object('ok', false, 'erro', 'Sem permissão.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'ciclo', t.ciclo, 'total_pedidos', t.total, 'valor_total', t.valor,
           'por_estado', t.por_estado
         ) order by t.ciclo desc), '[]'::jsonb)
    into v_linhas
    from (
      select ciclo, sum(n) as total, sum(soma) as valor,
             jsonb_object_agg(estado, n) as por_estado
        from (
          select ciclo, estado, count(*) as n, sum(valor_total) as soma
            from public.pedidos group by ciclo, estado
        ) e
        group by ciclo
    ) t;

  return jsonb_build_object('ok', true, 'dados', v_linhas);
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível carregar o resumo.');
end;
$function$;

revoke all on function public.cli_professor_resumo() from public, anon;
grant execute on function public.cli_professor_resumo() to authenticated;
