# Runbook — "Client outdated (405)" / atualização do whatsmeow

Guia para quando as instâncias Evolution v3 pararem de parear com o erro
`Client outdated (405)`. Explica a causa, como o conserto automático funciona e
como consertar à mão se o automático não bastar.

---

## Sintoma

No log do container (ou via `GET /instance/logs/:instanceId`):

```
[Client ERROR] Client outdated (405) connect failure (client version: 2.3000.xxxxxxx)
Received QR code event err-client-outdated
Login event: err-client-outdated
Unhandled event *events.ClientOutdated
```

Efeito: o handshake com o WhatsApp morre **antes** de gerar o QR, o
`/instance/pair` devolve `PairingCode` vazio e o `/instance/qr` responde
`no QR code available`. Nenhuma instância consegue parear.

## Causa raiz

O WhatsApp atualiza o protocolo de handshake a cada poucas semanas. A versão do
protocolo é compilada dentro da biblioteca **whatsmeow**. Quando a versão
embutida fica velha demais em relação à que o servidor do WhatsApp exige, o
servidor recusa a conexão com `405`.

A versão do whatsmeow vem de **duas fontes** neste repo, e as duas precisam estar
alinhadas:

1. **Submódulo `whatsmeow-lib`** — usado quando o checkout tem submódulos
   (ex.: build local com `git clone --recurse-submodules`).
2. **Fallback do `Dockerfile`** — usado em ambientes como o **EasyPanel**, que
   baixam o zip do repositório **sem** submódulos. Nesse caso o `whatsmeow-lib`
   vem vazio e o Dockerfile faz `git clone` + `checkout` por conta própria.

> ⚠️ Armadilha histórica: por muito tempo o fallback fixava um SHA antigo da fork
> `EvolutionAPI/whatsmeow`. Build local (que usava o submódulo) passava, mas
> produção (que caía no fallback) continuava velha e dava 405. Sempre confirme
> que **as duas fontes apontam para a mesma coisa** antes de concluir que
> "funcionou". Se local passa e produção dá 405, quase certo que divergiram.

Detalhe adicional: a fork `EvolutionAPI/whatsmeow` **parou em maio/2026**. A
fonte com protocolo atualizado é o whatsmeow **oficial `tulir/whatsmeow`**.

## Conserto automático (estado atual)

O fallback do `Dockerfile` clona **sempre o `main` mais recente do
`tulir/whatsmeow`**:

```dockerfile
ARG WHATSMEOW_REF=main
RUN if [ ! -f "./whatsmeow-lib/go.mod" ]; then \
      rm -rf ./whatsmeow-lib && \
      git clone https://github.com/tulir/whatsmeow.git ./whatsmeow-lib && \
      cd ./whatsmeow-lib && \
      git checkout "${WHATSMEOW_REF}"; \
    fi
```

**Consequência prática:** quando o 405 aparecer por protocolo velho, basta
**redeployar no EasyPanel** (botão Implantar no serviço `evolution_v3`). O build
pega o whatsmeow novo sozinho — sem editar SHA. Dá para agendar um redeploy
periódico para nunca mais pensar nisso.

### O que o automático NÃO cobre

- **Mudança de API do tulir.** Se um commit novo do tulir mudar assinaturas de
  função que o `evolution-go` usa, o `go build` do deploy **falha**. O EasyPanel
  mantém a imagem anterior no ar (não fica sem serviço), mas a versão nova não
  sobe até alguém ajustar o código. Ver "Conserto manual" abaixo.
- **Dependências transitivas novas.** Se o tulir novo exigir versões novas de
  `go.mau.fi/util`, protobuf etc., o `go.sum` precisa ser atualizado — o build do
  deploy não faz isso sozinho.

Não há gate de teste pré-deploy no EasyPanel, então o caso de quebra de API
exige intervenção manual. O automático cobre o caso **comum** (protocolo velho).

## Conserto manual (quando o automático não basta)

Use quando o redeploy não resolveu (quebra de API/deps) ou quando quiser travar
numa versão determinística.

Pré-requisitos: Go (a versão exigida no `go.mod`/`Dockerfile`), Docker, e o
checkout com o submódulo (`git submodule update --init`).

```bash
# 1. Pegar o commit mais novo do tulir
cd whatsmeow-lib
git remote add tulir https://github.com/tulir/whatsmeow.git   # só na 1a vez
git fetch tulir
git checkout tulir/main
git rev-parse HEAD        # <- este SHA é a referência

# 2. Validar o build e CORRIGIR quebras de API
cd ..
go mod tidy
go build ./...            # erros aqui = ajustes de assinatura a fazer no código
```

Exemplos reais de ajuste de API já feitos (nov/2026), em
`pkg/user/service/user_service.go`:

- `UpdateBlocklist(ctx, jid, action)` → ganhou parâmetro `dhash`:
  `UpdateBlocklist(ctx, jid, action, "")`
- `GetBlocklist(ctx)` → `GetBlocklist(ctx, "")`
- `SetStatusMessage(ctx, string)` → agora usa struct:
  `SetStatusMessage(ctx, types.SetStatusInput{Text: &status})`

Também pode ser necessário bumpar a imagem Go no `Dockerfile` (o tulir atual
exige Go 1.26).

```bash
# 3. Teste local REAL (reproduz o pareamento)
docker compose build
docker compose up -d
#   criar instância, POST /instance/connect, POST /instance/pair {phone}
#   LER o log: tem de aparecer "QR code generated" e NÃO pode ter "405"/"outdated"

# 4. Teste do caminho de PRODUÇÃO (reproduz o EasyPanel = sem submódulos)
#    Clonar a branch SEM --recurse-submodules num diretório limpo e buildar:
git clone --branch <branch> --single-branch <repo-url> /tmp/evo-test
cd /tmp/evo-test            # whatsmeow-lib fica VAZIO -> força o fallback
docker build -t evo-test .  # o build tem de clonar tulir e compilar (exit 0)
```

> O passo 4 é o que pega a divergência local-vs-produção. Build local comum usa o
> submódulo; só o clone sem submódulos exercita o fallback que o EasyPanel usa.

```bash
# 5. Se precisar TRAVAR numa versão (build determinístico), em vez do main:
#    - submódulo: git checkout <SHA> dentro de whatsmeow-lib
#    - Dockerfile: trocar "main" por <SHA> no ARG WHATSMEOW_REF (ou passar
#      --build-arg WHATSMEOW_REF=<SHA> no deploy)

# 6. PR -> merge -> Implantar no EasyPanel -> parear uma instância de teste
#    de verdade e confirmar no log: zero 405.
```

## Como testar o pareamento (checagem de sucesso)

1. `POST /instance/create` com `{name, token}` (header `apikey` = global).
2. `POST /instance/connect` com `{name, subscribe:["MESSAGE","CONNECTION"], immediate:true, phone:"<numero>"}` (header `apikey` = token da instância).
3. `POST /instance/pair` com `{phone:"<numero>"}` → deve devolver `PairingCode` não vazio.
4. `GET /instance/qr` → deve devolver um PNG (`data:image/...`).
5. Log (`GET /instance/logs/:id`): procure `QR code generated` e **garanta que
   não há** `405` nem `outdated`. Esse é o veredito.

Pareamento real (escanear QR / digitar código no celular) é a confirmação final;
não há como automatizar essa parte.

## Referências

- whatsmeow oficial: https://github.com/tulir/whatsmeow
- Fork EvolutionAPI (congelada em maio/2026): https://github.com/EvolutionAPI/whatsmeow
- PRs relacionados: #1 (SetWAVersion), #2 (bump proto fork), #3 (migração p/
  tulir), #4 (fallback auto-atualiza).
