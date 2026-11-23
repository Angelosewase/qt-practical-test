# syntax=docker/dockerfile:1.7
# Go API (ProjectHub backend). Build context: repository root.

# ---- build: compile a static binary -------------------------------------
FROM golang:1.23.12-alpine3.21 AS build
WORKDIR /src/app/backend
ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
COPY app/backend/go.mod app/backend/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY app/backend/ ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags="-s -w" -o /out/projecthub-api .

# ---- runtime: minimal image, non-root user ------------------------------
FROM alpine:3.21.10 AS runtime
RUN addgroup -S -g 10001 app \
 && adduser -S -D -H -u 10001 -G app app
COPY --from=build /out/projecthub-api /usr/local/bin/projecthub-api
ENV PORT=8080 GIN_MODE=release
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/api/health"]
ENTRYPOINT ["/usr/local/bin/projecthub-api"]
