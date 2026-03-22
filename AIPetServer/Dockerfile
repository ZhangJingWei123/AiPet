FROM golang:1.24.11-alpine AS builder

WORKDIR /src

RUN apk add --no-cache ca-certificates git

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o /out/aipet-server .

FROM alpine:3.19

RUN apk add --no-cache ca-certificates wget

WORKDIR /app

COPY --from=builder /out/aipet-server /app/aipet-server

ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1

CMD ["/app/aipet-server"]
