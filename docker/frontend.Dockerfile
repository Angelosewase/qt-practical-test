# syntax=docker/dockerfile:1.7
# Vite React SPA (ProjectHub frontend), served as static files. Build context: repository root.

# ---- build: produce dist/ ------------------------------------------------
FROM node:20.19.6-alpine3.21 AS build
WORKDIR /src/app/frontend
COPY app/frontend/package.json app/frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund
COPY app/frontend/ ./
# VITE_API_URL is compiled into the bundle at build time. /api routes through the NGINX gateway.
ARG VITE_API_URL=/api
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build

# ---- runtime: unprivileged NGINX (runs as uid 101, listens on 8080) ------
FROM nginxinc/nginx-unprivileged:1.27.5-alpine AS runtime
COPY docker/frontend-nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/app/frontend/dist /usr/share/nginx/html
USER 101
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/"]
