-- Clientify — nomes de clientes reais em vez de "Cliente 1", "Cliente 2"...
-- Pedido do Germano: os nomes pareciam claramente gerados, sem realismo.
-- Combina primeiro nome + apelido de duas listas PT-PT, escolhidos ao
-- acaso por pedido (não há garantia de não-repetição — na vida real
-- também há clientes com o mesmo nome).

create or replace function public.cli_gerar_ciclo_interno(p_ciclo text, p_valor_maximo bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
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
  v_cliente_nome text;
  v_primeiros_nomes text[] := array[
    'Maria','João','Francisco','António','Ana','Pedro','Sofia','Miguel','Beatriz','Rui',
    'Catarina','Tiago','Inês','Diogo','Carolina','Bruno','Mariana','Ricardo','Joana','André',
    'Rita','Nuno','Sara','Hugo','Leonor','Gonçalo','Matilde','Rodrigo','Marta','Vasco',
    'Teresa','Duarte','Carla','Fábio','Cristina','Luís','Patrícia','Manuel','Helena','José'
  ];
  v_apelidos text[] := array[
    'Silva','Santos','Ferreira','Pereira','Oliveira','Costa','Rodrigues','Martins','Jesus','Sousa',
    'Fernandes','Gonçalves','Gomes','Lopes','Marques','Alves','Almeida','Ribeiro','Pinto','Carvalho',
    'Teixeira','Moreira','Correia','Mendes','Nunes','Soares','Vieira','Monteiro','Cardoso','Rocha'
  ];
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
      v_n_itens := 1 + floor(random() * 3)::int;
      v_cliente_nome := v_primeiros_nomes[1 + floor(random() * array_length(v_primeiros_nomes, 1))::int]
                         || ' ' ||
                         v_apelidos[1 + floor(random() * array_length(v_apelidos, 1))::int];

      insert into public.pedidos(id, empresa_cedula, cliente_nome, ciclo, estado, valor_total)
      values (v_pid, r_emp.cedula, v_cliente_nome, p_ciclo, 'enviado', 0);

      for r_prod in
        select * from public.produtos where empresa_cedula = r_emp.cedula
         order by random() limit v_n_itens
      loop
        if v_primeiro then
          v_qtd_max := greatest(1, least(r_prod.qtd_dia, (v_orcamento / r_prod.preco_venda)::int));
          v_primeiro := false;
        else
          if v_orcamento < r_prod.preco_venda then continue; end if;
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
