// Clientify — lista de pedidos da empresa, com a ação certa por estado.

const elAVerificar = document.getElementById('a-verificar');
const elEntrada = document.getElementById('entrada');
const elPainel = document.getElementById('painel');
const elLista = document.getElementById('lista-pedidos');
const elSegmentado = document.getElementById('segmentado');
const elJanelaFatura = document.getElementById('janela-fatura');

let PEDIDOS_CACHE = null;
let filtroAtual = 'todos';
let pedidoParaFatura = null;
let NOME_EMPRESA = null;
let CEDULA_PESSOA = null;

function mostrarPainel() { elAVerificar.hidden = true; elEntrada.hidden = true; elPainel.hidden = false; }
function mostrarEntrada() { elAVerificar.hidden = true; elPainel.hidden = true; elEntrada.hidden = false; }

const ROTULO_ESTADO = {
  enviado: 'Novo', aceite: 'Aceite', fatura_emitida: 'Com fatura',
  pago: 'Pago', 'concluído': 'Concluído',
};
const SELO_ESTADO = {
  enviado: 'neutro', aceite: 'info', fatura_emitida: 'aviso',
  pago: 'sucesso', 'concluído': 'sucesso',
};

async function carregarPedidos(forcar) {
  if (PEDIDOS_CACHE && !forcar) return { ok: true, dados: PEDIDOS_CACHE };
  const r = await api('cli_meus_pedidos');
  if (r.ok) PEDIDOS_CACHE = r.dados;
  return r;
}

function aplicarFiltro(pedidos) {
  if (filtroAtual === 'todos') return pedidos;
  return pedidos.filter((p) => p.estado === filtroAtual);
}

function botaoAcao(p) {
  if (p.estado === 'enviado') {
    return `<button type="button" class="cl-botao cl-botao-primario cl-botao-pequeno" data-aceitar="${p.pedido_id}">Aceitar</button>`;
  }
  if (p.estado === 'aceite') {
    return `<button type="button" class="cl-botao cl-botao-primario cl-botao-pequeno" data-ligar-fatura="${p.pedido_id}">Ligar fatura</button>`;
  }
  if (p.estado === 'fatura_emitida') {
    return `<button type="button" class="cl-botao cl-botao-primario cl-botao-pequeno" data-liberar="${p.pedido_id}">Confirmar pagamento</button>`;
  }
  if (p.estado === 'pago') {
    return `<button type="button" class="cl-botao cl-botao-primario cl-botao-pequeno" data-concluir="${p.pedido_id}">Concluir</button>`;
  }
  return '';
}

function linhaPedido(p) {
  const itens = p.itens.map((it) => `${it.quantidade}× ${esc(it.produto)}`).join(', ');
  return `
    <article class="cl-cartao" style="margin-bottom:var(--cl-e3)">
      <div class="cl-fila" style="justify-content:space-between">
        <div>
          <span class="cl-selo cl-selo-${SELO_ESTADO[p.estado] || 'neutro'}"><span class="ponto"></span>${esc(ROTULO_ESTADO[p.estado] || p.estado)}</span>
          <span class="cl-caption" style="margin-left:8px">${esc(p.ciclo)} · ${formatarData(p.criada_em)}</span>
        </div>
        <b>${esc(formatarDinheiro(p.valor_total))}</b>
      </div>
      <p class="cl-body" style="margin-top:var(--cl-e2)"><b>${esc(p.cliente_nome)}</b></p>
      <p class="cl-caption" style="margin-top:2px">${itens || 'sem itens'}</p>
      <div class="cl-fila" style="margin-top:var(--cl-e3)">
        ${botaoAcao(p)}
        <button type="button" class="cl-botao cl-botao-secundario cl-botao-pequeno" data-pdf="${p.pedido_id}">${p.confirmacao_pdf_caminho ? 'Ver confirmação (PDF)' : 'Gerar confirmação (PDF)'}</button>
      </div>
    </article>`;
}

async function renderizar() {
  const r = await carregarPedidos();
  if (!r.ok) { elLista.innerHTML = `<p class="cl-vazio">${esc(r.erro)}</p>`; return; }
  const visiveis = aplicarFiltro(r.dados);
  elLista.innerHTML = visiveis.length
    ? visiveis.map(linhaPedido).join('')
    : '<p class="cl-vazio">Nenhum pedido aqui.</p>';
  ligarAcoes();
}

function ligarAcoes() {
  elLista.querySelectorAll('[data-aceitar]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      const r = await api('cli_aceitar', { p_pedido_id: btn.dataset.aceitar });
      if (!r.ok) { alert(r.erro); btn.disabled = false; return; }
      await carregarPedidos(true); await renderizar();
    });
  });
  elLista.querySelectorAll('[data-ligar-fatura]').forEach((btn) => {
    btn.addEventListener('click', () => {
      pedidoParaFatura = btn.dataset.ligarFatura;
      document.getElementById('fatura-doc-id').value = '';
      mostrarMsg(document.getElementById('msg-fatura'), '');
      elJanelaFatura.showModal();
    });
  });
  elLista.querySelectorAll('[data-liberar]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      const r = await api('cli_liberar', { p_pedido_id: btn.dataset.liberar });
      if (!r.ok) { alert(r.erro); btn.disabled = false; return; }
      await carregarPedidos(true); await renderizar();
    });
  });
  elLista.querySelectorAll('[data-concluir]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      const r = await api('cli_concluir', { p_pedido_id: btn.dataset.concluir });
      if (!r.ok) { alert(r.erro); btn.disabled = false; return; }
      await carregarPedidos(true); await renderizar();
    });
  });
  elLista.querySelectorAll('[data-pdf]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const pedido = (PEDIDOS_CACHE || []).find((p) => p.pedido_id === btn.dataset.pdf);
      if (!pedido) return;
      const jaTinhaConfirmacao = !!pedido.confirmacao_pdf_caminho;
      btn.disabled = true;
      btn.textContent = 'A preparar…';
      await mostrarConfirmacaoPdf(pedido, NOME_EMPRESA, CEDULA_PESSOA);
      if (!jaTinhaConfirmacao && pedido.confirmacao_pdf_caminho) {
        await renderizar(); // troca o botão para "Ver confirmação"
      } else {
        btn.disabled = false;
        btn.textContent = jaTinhaConfirmacao ? 'Ver confirmação (PDF)' : 'Gerar confirmação (PDF)';
      }
    });
  });
}

document.getElementById('fatura-cancelar').addEventListener('click', () => elJanelaFatura.close());
document.getElementById('fatura-confirmar').addEventListener('click', async () => {
  const msg = document.getElementById('msg-fatura');
  const bruto = document.getElementById('fatura-doc-id').value.trim();
  // aceita colar o ID solto ou o link inteiro (documento.html?id=...)
  const m = bruto.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  if (!m) { mostrarMsg(msg, 'Cole um ID de documento válido.', 'erro'); return; }
  mostrarMsg(msg, 'A ligar…');
  const r = await api('cli_emitir_fatura', { p_pedido_id: pedidoParaFatura, p_fatura_doc_id: m[0] });
  if (!r.ok) { mostrarMsg(msg, r.erro, 'erro'); return; }
  elJanelaFatura.close();
  await carregarPedidos(true); await renderizar();
});

elSegmentado.querySelectorAll('button').forEach((btn) => {
  btn.addEventListener('click', () => {
    filtroAtual = btn.dataset.filtro;
    elSegmentado.querySelectorAll('button').forEach((b) => b.setAttribute('aria-current', String(b === btn)));
    renderizar();
  });
});

ligarVerSenha();
ligarFormularioLogin('form-login', async () => {
  const ctx = await quemSou();
  if (seProfessorRedirecionar(ctx)) return;
  if (!ctx || !ctx.empresa) {
    mostrarMsg(document.querySelector('#form-login .cl-msg'),
      'Esta conta não está associada a nenhuma empresa.', 'erro');
    await sb.auth.signOut();
    return;
  }
  NOME_EMPRESA = ctx.empresa.nome;
  CEDULA_PESSOA = ctx.pessoa.cedula;
  mostrarPainel();
  montarTopo(ctx);
  await renderizar();
});

(async function arrancar() {
  const ctx = await quemSou();
  if (seProfessorRedirecionar(ctx)) return;
  if (!ctx || !ctx.empresa) { mostrarEntrada(); return; }
  NOME_EMPRESA = ctx.empresa.nome;
  CEDULA_PESSOA = ctx.pessoa.cedula;
  mostrarPainel();
  montarTopo(ctx);
  await renderizar();
})();
