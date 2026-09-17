// Clientify — painel da professora: gerar ciclo, acompanhar o resumo.

const elAVerificar = document.getElementById('a-verificar');
const elEntrada = document.getElementById('entrada');
const elPainel = document.getElementById('painel');
const elListaResumo = document.getElementById('lista-resumo');

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

function cartaoCiclo(c) {
  const selos = Object.entries(c.por_estado || {})
    .map(([estado, n]) => `<span class="cl-selo cl-selo-${SELO_ESTADO[estado] || 'neutro'}"><span class="ponto"></span>${esc(ROTULO_ESTADO[estado] || estado)}: ${n}</span>`)
    .join(' ');
  return `
    <article class="cl-cartao" style="margin-bottom:var(--cl-e3)">
      <div class="cl-fila" style="justify-content:space-between">
        <h3 class="cl-label" style="font-size:15px">${esc(c.ciclo)}</h3>
        <span class="cl-suave cl-caption">${c.total_pedidos} pedidos · ${formatarDinheiro(c.valor_total)}</span>
      </div>
      <div class="cl-fila" style="margin-top:var(--cl-e3);gap:6px">${selos}</div>
    </article>`;
}

async function carregarResumo() {
  const r = await api('cli_professor_resumo');
  if (!r.ok) { elListaResumo.innerHTML = `<p class="cl-vazio">${esc(r.erro)}</p>`; return; }
  elListaResumo.innerHTML = r.dados.length
    ? r.dados.map(cartaoCiclo).join('')
    : '<p class="cl-vazio">Ainda não gerou nenhum ciclo.</p>';
}

document.getElementById('form-gerar').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const msg = document.getElementById('msg-gerar');
  const btn = ev.target.querySelector('button[type="submit"]');
  btn.disabled = true;
  mostrarMsg(msg, 'A gerar…');
  const r = await api('cli_gerar_ciclo', {
    p_ciclo: document.getElementById('g-ciclo').value,
    p_valor_medio: Math.round(Number(document.getElementById('g-valor').value) * 100),
  });
  btn.disabled = false;
  if (!r.ok) { mostrarMsg(msg, r.erro, 'erro'); return; }
  mostrarMsg(msg, `${r.dados.pedidos_gerados} pedido(s) gerado(s) para ${r.dados.empresas_atendidas} empresa(s).`, 'ok');
  await carregarResumo();
});

ligarVerSenha();
ligarFormularioLogin('form-login', async () => {
  const ctx = await quemSou();
  if (!ctx || !ctx.pessoa || ctx.pessoa.papel !== 'professor') {
    mostrarMsg(document.querySelector('#form-login .cl-msg'),
      'Esta conta não tem acesso à área da professora.', 'erro');
    await sb.auth.signOut();
    return;
  }
  mostrarPainel();
  montarTopo(ctx);
  await carregarResumo();
});

(async function arrancar() {
  const ctx = await quemSou();
  if (!ctx || !ctx.pessoa || ctx.pessoa.papel !== 'professor') { mostrarEntrada(); return; }
  mostrarPainel();
  montarTopo(ctx);
  await carregarResumo();
})();
