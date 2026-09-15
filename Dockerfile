# ---- Stage 1: build the static assets ----
# This stage needs the full Node toolchain, but none of it ships in the
# final image -- only its output (the dist/ folder) gets copied forward.
FROM node:20-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# Vite bakes VITE_* variables into the JS bundle at BUILD time, not at
# container runtime, so they can't be passed with `docker run -e` like the
# backend's secrets can. They have to be build args here. Writing them to
# .env.production works because `vite build` runs in "production" mode by
# default and loads that file automatically.
ARG VITE_BACKEND_URL
ARG VITE_CURRENCY
RUN printf "VITE_BACKEND_URL=%s\nVITE_CURRENCY=%s\n" "$VITE_BACKEND_URL" "$VITE_CURRENCY" > .env.production

RUN npm run build

# ---- Stage 2: serve the static output with nginx ----
# No Node, no source code, no node_modules in this image -- just the
# compiled dist/ output behind a web server. This is the whole point of
# a multi-stage build: a ~50MB nginx-alpine image instead of shipping the
# ~300MB+ Node build toolchain to production.
FROM nginx:1.27-alpine AS run

# The stock main nginx.conf hardcodes `pid /var/run/nginx.pid;`, which the
# unprivileged "nginx" user below can't write to -- so we ship a full
# replacement main config (pid in /tmp) instead of trying to patch it.
COPY nginx.main.conf /etc/nginx/nginx.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

# The official nginx image ships a pre-created "nginx" user. Binding to
# 8080 instead of the privileged port 80 lets us run as that unprivileged
# user instead of root.
USER nginx
EXPOSE 8080

# 127.0.0.1, not localhost: Alpine's musl libc resolves "localhost" to the
# IPv6 loopback (::1) first, and plain `listen 8080;` only binds IPv4 --
# that mismatch caused real connection-refused failures here.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
