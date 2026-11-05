FROM golang:1.26-alpine AS build

RUN apk update && apk add --no-cache git build-base libjpeg-turbo-dev libwebp-dev

WORKDIR /build

# Copiar apenas arquivos de dependências primeiro para cachear o download
COPY go.mod go.sum ./

# Copiar whatsmeow-lib que é uma dependência local
COPY whatsmeow-lib/ ./whatsmeow-lib/

# Fallback para ambientes como Easypanel (que baixam o zip do repositório sem submódulos)
# Aponta para o whatsmeow oficial (tulir) com proto compativel com o WhatsApp atual — corrige "Client outdated (405)".
RUN if [ ! -f "./whatsmeow-lib/go.mod" ]; then \
      rm -rf ./whatsmeow-lib && \
      git clone https://github.com/tulir/whatsmeow.git ./whatsmeow-lib && \
      cd ./whatsmeow-lib && \
      git checkout 54038813c47f3f351eb6fcaafab0e1b99d676850; \
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
