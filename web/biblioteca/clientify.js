// Clientify — helpers partilhados. Mesmo padrão do emdia.js/openlab.js:
// um ficheiro só, as páginas do app importam.

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function formatarDinheiro(centavos) {
  const v = Number(centavos || 0) / 100;
  return '€ ' + v.toLocaleString('pt-PT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatarData(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleDateString('pt-PT', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

function versaoDoSite() {
  const m = document.querySelector('meta[name="clientify-versao"]');
  return (m && m.content) ? m.content : '';
}
function comVersao(href) {
  const v = versaoDoSite();
  if (!v || /^https?:/.test(href)) return href;
  const [caminho, resto] = href.split('?');
  const params = new URLSearchParams(resto || '');
  params.set('v', v);
  return caminho + '?' + params.toString();
}

// ── sessão ───────────────────────────────────────────────────────────
async function quemSou() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return null;
  const { data: pessoa } = await sb
    .from('pessoas').select('cedula, nome, papel, empresa_id')
    .eq('id', data.session.user.id).single();
  if (!pessoa) return null;
  let empresa = null;
  if (pessoa.empresa_id) {
    const { data: e } = await sb
      .from('empresas').select('cedula, nome').eq('id', pessoa.empresa_id).single();
    empresa = e || null;
  }
  return { pessoa, empresa };
}

// Só a professora tem professor.html; mesma lição do EmDia (a conta de
// teste pode ter uma empresa ligada por acaso — o papel manda sempre).
function seProfessorRedirecionar(ctx) {
  if (ctx && ctx.pessoa && ctx.pessoa.papel === 'professor') {
    window.location.replace(comVersao('professor.html'));
    return true;
  }
  return false;
}

function mostrarMsg(el, texto, tipo) {
  if (!el) return;
  el.textContent = texto || '';
  el.className = 'cl-msg' + (tipo ? ' cl-msg-' + tipo : '');
}

function ligarVerSenha(sufixo) {
  const btn = document.getElementById('btn-ver-senha' + (sufixo || ''));
  const campo = document.getElementById('senha' + (sufixo || ''));
  if (!btn || !campo) return;
  btn.addEventListener('click', () => {
    const aMostrar = campo.type === 'password';
    campo.type = aMostrar ? 'text' : 'password';
    btn.textContent = aMostrar ? 'Esconder' : 'Mostrar';
    btn.setAttribute('aria-pressed', String(aMostrar));
    campo.focus();
  });
}

function ligarFormularioLogin(idForm, aoEntrar) {
  const form = document.getElementById(idForm);
  if (!form) return;
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const msg = form.querySelector('.cl-msg');
    const btn = form.querySelector('button[type="submit"]');
    if (btn) btn.disabled = true;
    mostrarMsg(msg, 'A entrar…');
    const { error } = await sb.auth.signInWithPassword({
      email: form.querySelector('[name="email"]').value,
      password: form.querySelector('[name="senha"]').value,
    });
    if (btn) btn.disabled = false;
    if (error) {
      mostrarMsg(msg, 'Email ou senha errados.', 'erro');
      return;
    }
    mostrarMsg(msg, '');
    await aoEntrar();
  });
}

// ── confirmação de compra em PDF — gerada no browser (jsPDF), abre
// numa nova aba para ver/imprimir/guardar. Não é a fatura assinada
// (essa continua a viver no Subsight) — é só o comprovativo do que foi
// encomendado, como um recibo de encomenda de uma loja a sério. ──────
function gerarConfirmacaoPdf(pedido, nomeEmpresa) {
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF();
  const codigo = pedido.pedido_id.slice(0, 8).toUpperCase();

  doc.setFontSize(18);
  doc.text('Confirmação de compra', 14, 20);

  doc.setFontSize(10);
  doc.setTextColor(90);
  doc.text('Documento gerado automaticamente pelo Clientify — não é a fatura fiscal.', 14, 27);

  doc.setTextColor(20);
  doc.setFontSize(11);
  const linhas = [
    ['Nº do pedido', codigo],
    ['Vendedor', nomeEmpresa || '—'],
    ['Cliente', pedido.cliente_nome],
    ['Ciclo', pedido.ciclo],
    ['Data', formatarData(pedido.criada_em)],
    ['Estado', pedido.estado],
  ];
  let y = 38;
  linhas.forEach(([rotulo, valor]) => {
    doc.setFont(undefined, 'bold');
    doc.text(rotulo + ':', 14, y);
    doc.setFont(undefined, 'normal');
    doc.text(String(valor), 55, y);
    y += 7;
  });

  doc.autoTable({
    startY: y + 4,
    head: [['Produto', 'Quantidade', 'Preço unit.', 'Subtotal']],
    body: pedido.itens.map((it) => [
      it.produto,
      String(it.quantidade),
      formatarDinheiro(it.preco_unit),
      formatarDinheiro(it.preco_unit * it.quantidade),
    ]),
    foot: [['', '', 'Total', formatarDinheiro(pedido.valor_total)]],
    theme: 'grid',
    headStyles: { fillColor: [232, 80, 2] },
    footStyles: { fillColor: [245, 245, 245], textColor: 20, fontStyle: 'bold' },
  });

  const url = doc.output('bloburl');
  window.open(url, '_blank');
}

// ── topo (menu sempre em cima) — a empresa e a professora veem nomes
// diferentes, mesmo padrão do EmDia ─────────────────────────────────
function montarTopo(ctx) {
  const el = document.getElementById('topo');
  if (!el) return;
  const nome = ctx.pessoa.papel === 'professor' ? 'Painel da professora' : (ctx.empresa ? ctx.empresa.nome : ctx.pessoa.nome);
  el.innerHTML = `
    <div class="cl-topo">
      <div class="cl-topo-int">
        <a class="cl-marca" href="${comVersao(ctx.pessoa.papel === 'professor' ? 'professor.html' : 'index.html')}">
          <img src="favicon-32.png" alt="" />
          Clientify
        </a>
        <div class="cl-fila">
          <span class="cl-suave cl-caption">${esc(nome)}</span>
          <button type="button" class="cl-botao cl-botao-terciario cl-botao-pequeno" id="btn-sair">Sair</button>
        </div>
      </div>
    </div>`;
  document.getElementById('btn-sair').addEventListener('click', async () => {
    await sb.auth.signOut();
    window.location.reload();
  });
}
