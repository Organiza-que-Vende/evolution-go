FROM golang:1.26-alpine AS build

RUN apk update && apk add --no-cache git build-base libjpeg-turbo-dev libwebp-dev

WORKDIR /build

# Copiar apenas arquivos de dependências primeiro para cachear o download
COPY go.mod go.sum ./

# Copiar whatsmeow-lib que é uma dependência local
COPY whatsmeow-lib/ ./whatsmeow-lib/

# Fallback para ambientes como Easypanel (que baixam o zip do repositório sem submódulos).
# Clona SEMPRE o main mais recente do whatsmeow oficial (tulir) para que cada
# redeploy traga o proto novo e o "Client outdated (405)" se resolva sozinho,
# sem precisar atualizar um SHA a mao. Trade-off: build nao-determinístico — se
# o tulir publicar uma mudança de API, o build do deploy pode quebrar; o EasyPanel
# mantem a imagem anterior no ar nesse caso (nao fica sem serviço). O proximo
# redeploy apos corrigir a API volta a pegar o main novo.
# Para TRAVAR numa versao conhecida (build determinístico), troque "main" por um
# SHA: git checkout <sha>.
ARG WHATSMEOW_REF=main
RUN if [ ! -f "./whatsmeow-lib/go.mod" ]; then \
      rm -rf ./whatsmeow-lib && \
      git clone https://github.com/tulir/whatsmeow.git ./whatsmeow-lib && \
      cd ./whatsmeow-lib && \
      git checkout "${WHATSMEOW_REF}"; \
    fi

# Agora fazer download das dependências (com replace funcionando)
RUN go mod download

# Copiar o restante do código
COPY . .

ARG VERSION=dev
RUN CGO_ENABLED=1 go build -ldflags "-X main.version=${VERSION}" -o server ./cmd/evolution-go

FROM alpine:3.19.1 AS final

RUN apk update && apk add --no-cache tzdata ffmpeg libjpeg-turbo libwebp

WORKDIR /app

COPY --from=build /build/server .
COPY --from=build /build/manager/dist ./manager/dist
COPY --from=build /build/VERSION ./VERSION

ENV TZ=America/Sao_Paulo

ENTRYPOINT ["/app/server"]
