// Clientify — garante que ninguém fica preso numa versão velha. Mesmo
// mecanismo do EmDia/OpenLab: o GitHub Pages não deixa mudar o
// Cache-Control (max-age=600) do HTML, por isso a página compara a sua
// versão com versao.json e recarrega com ?v= quando não bate certo. No
// máximo uma recarga por página/versão (sessionStorage), para nunca
// entrar em ciclo; sem rede, segue com o que tem.

(function () {
  const meta = document.querySelector('meta[name="clientify-versao"]');
  if (!meta || !meta.content) return;
  const minha = meta.content;

  function jaTentei(versao) {
    const chave = 'cl-recarga:' + window.location.pathname + ':' + versao;
    try {
      if (sessionStorage.getItem(chave)) return true;
      sessionStorage.setItem(chave, '1');
      return false;
    } catch (e) {
      return true;
    }
  }

  fetch('versao.json?t=' + Date.now(), { cache: 'no-store' })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (d) {
      if (!d || !d.versao || d.versao === minha) return;
      if (jaTentei(d.versao)) return;

      const u = new URL(window.location.href);
      u.searchParams.set('v', d.versao);
      window.location.replace(u.toString());
    })
    .catch(function () { /* offline: fica-se com esta versão */ });
})();
