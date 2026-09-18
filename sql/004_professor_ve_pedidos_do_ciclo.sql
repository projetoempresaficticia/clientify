-- 004_professor_ve_pedidos_do_ciclo.sql — o "Resumo por ciclo" da
-- professora só agregava contagens (nº de pedidos, valor total, contagem
-- por estado) sem dizer para que EMPRESA cada pedido foi, nem dar
-- acesso à confirmação em PDF. Acrescenta um detalhe expansível por
-- ciclo, mesmo padrão "Ver empresas" já usado no EmDia.

create or replace function public.cli_professor_pedidos_do_ciclo(p_ciclo text)
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
           'pedido_id', p.id, 'empresa_cedula', p.empresa_cedula, 'empresa_nome', e.nome,
           'cliente_nome', p.cliente_nome, 'ciclo', p.ciclo, 'valor_total', p.valor_total, 'estado', p.estado,
           'confirmacao_pdf_caminho', p.confirmacao_pdf_caminho, 'criada_em', p.criada_em,
           'itens', (
             select coalesce(jsonb_agg(jsonb_build_object(
                      'produto', pr.nome, 'quantidade', pi.quantidade, 'preco_unit', pi.preco_unit
                    )), '[]'::jsonb)
             from public.pedido_itens pi join public.produtos pr on pr.id = pi.produto_id
             where pi.pedido_id = p.id
           )
         ) order by e.nome, p.criada_em), '[]'::jsonb)
    into v_linhas
    from public.pedidos p
    join public.empresas e on e.cedula = p.empresa_cedula
   where p.ciclo = p_ciclo;

  return jsonb_build_object('ok', true, 'dados', v_linhas);
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível listar os pedidos do ciclo.');
end;
$function$;

revoke all on function public.cli_professor_pedidos_do_ciclo(text) from public, anon;
grant execute on function public.cli_professor_pedidos_do_ciclo(text) to authenticated;

-- ── a professora também pode gerar/ver a confirmação (auditoria) ────
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
  if v_pedido.empresa_cedula is distinct from public.fn_minha_empresa_cedula()
     and not public.fn_e_professor() then
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
