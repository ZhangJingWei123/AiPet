FROM golang:1.22-alpine AS builder

WORKDIR /app

RUN apk add --no-cache ca-certificates git

COPY go.mod ./
COPY . ./

RUN go mod tidy && \
    go build -o aipet-server ./...

FROM alpine:3.19

WORKDIR /app

RUN apk add --no-cache ca-certificates && update-ca-certificates

COPY --from=builder /app/aipet-server /app/aipet-server

ENV PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1

CMD ["/app/aipet-server"]

