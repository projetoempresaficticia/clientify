# Clientify

Gerador de clientes externos — a "torneira de receita" do ecossistema
(Prepara Portugal). Antes chamava-se `pp-clientes`.

**Status:** completo — backend, identidade visual e app testados com SQL
real e Puppeteer (fluxo de ponta a ponta, incluindo assinatura real no
Subsight).
**Depende de:** pp-base, pp-identidade, prepacoin, pp-correio, pp-assinatura, openlab

Documentação completa (PRDs e decisões) em
[prepara-portugal-docs](https://github.com/projetoempresaficticia/prepara-portugal-docs).

## O que faz

A única fonte de dinheiro **novo** no ecossistema — tudo o resto só
redistribui ou drena. A cada ciclo, `cli_gerar_ciclo(ciclo, valor_medio)`
cria pedidos para cada empresa com catálogo (piso proporcional ao custo
dos produtos + bónus modesto por mérito recente), entrega-os no correio.
O dinheiro só entra depois de todo um fluxo administrativo real:

```
enviado → aceite → fatura_emitida → pago → concluído
```

A empresa aceita (`cli_aceitar`), cria e assina uma Declaração no
**Subsight** provando que cumpriu o pedido, liga esse documento ao
pedido (`cli_emitir_fatura`), e só então confirma o pagamento
(`cli_liberar`) — que verifica a assinatura (`ass_verificar`) e, só se
válida, injeta o valor de venda na conta da empresa
(`banco_creditar_inicial_interno`, no Prepacoin).

`cli_gerar_ciclo` já existia no banco antes desta sessão, mas era uma
cópia da skill nunca testada com bugs reais (sem gate de permissão, sem
idempotência, remetente do correio era a string `'GERADOR'` em vez de
uma cédula real, só escolhia 1 produto por pedido). Tudo corrigido — ver
`sql/001_clientify.sql` para o detalhe de cada correção.

## App

Duas páginas, mesmo padrão do EmDia/OpenLab:
- **`index.html`** (empresa): lista de pedidos com filtro por estado, e
  o botão certo para cada um — Aceitar, Ligar fatura (com link direto
  para o Subsight e campo para colar o ID do documento assinado),
  Confirmar pagamento, Concluir.
- **`professor.html`**: agendamento automático da geração de ciclos
  (diário/semanal/quinzenal/mensal/personalizado), formulário manual
  "Gerar ciclo" e um resumo por ciclo com a contagem de pedidos em cada
  estado.

## Agendamento automático

Mesmo padrão já validado no EmDia: um relógio diário do `pg_cron`
(`clientify-verificar-gerar`, 09:00 UTC) só gera um ciclo novo quando o
intervalo escolhido pela professora já passou desde a última vez — sem
precisar de recriar o job para mudar o ritmo. Configuração em
`public.cli_agendamento` (linha única), editável pelo painel da
professora (`cli_definir_agendamento`). `cli_gerar_ciclo` exige sessão
real de professor (`fn_e_professor()`), que o `pg_cron` nunca tem — por
isso o miolo vive em `cli_gerar_ciclo_interno` (sem gate, nunca exposto
a `anon`/`authenticated`), mesmo padrão `_interno`/wrapper de sempre. O
ciclo automático chama-se pela data de emissão (`YYYY-MM-DD`), não por
um nome livre — necessário para uma cadência diária/semanal não colidir
com a idempotência de `cli_gerar_ciclo` (um ciclo só se gera uma vez).
Ver `sql/002_agendamento_automatico.sql`.

## Identidade visual

Tema escuro (preto puro), Inter, laranja de marca — a partir dos
ficheiros enviados pelo Germano (ícone, kit, fundo de login), 17 de
setembro de 2026. Ver `biblioteca.html`. Duas correções de contraste
medidas com o auditor WCAG real: o botão primário usa sempre texto
preto sobre o laranja (branco falha, 3,57:1); cada um dos cinco selos de
estado tem a cor de texto (preta ou branca) que passa no seu fundo
específico — ver a nota na própria biblioteca.
