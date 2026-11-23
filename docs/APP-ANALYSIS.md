# Application analysis: what the code really is

Source analysed: `mydiary/` (the nested clone of `https://git.qtglobal.rw/devops-challenge/mydiary.git`, HEAD `256d50b`). It is copied unchanged into `app/`.

## 1. Summary

The code is **ProjectHub**, a project and task manager with JWT login and three roles. It is not "MyDiary" as the brief describes. The stack is different too:

| Part | Brief says | Code actually is |
|---|---|---|
| Frontend | Next.js 14 (Node 20) | React 18.3 SPA built with **Vite 5.4** (static files, no server-side rendering) |
| Backend | Spring Boot 3 (Java 21, Maven) | **Go 1.23** API using **Gin 1.10.1** (single static binary) |
| Database | PostgreSQL 16 | **MongoDB 7** (`mongo-driver` 1.17.3) |
| Cache | Redis | **Valkey 8+** (`valkey-go` 1.0.69, Redis-compatible protocol), optional |
| Domain | Diary entries with mood, tags, search, streaks | Projects with team members, tasks (todo / in progress / done), dashboard stats |
| Roles | USER, ADMIN | `admin`, `manager`, `member` |
| Health path | `/api/health`, `/actuator/health` | `/api/health` only. There is no `/actuator`. |
| Search | Entry search | **No search feature** exists in the API or the UI (grep for "search" in backend and frontend: zero hits) |

Consequence: the functional test "create and search entries" is mapped to what exists here: create a project, create a task, list both, and filter by team membership. This is recorded in section 7.

## 2. Repository layout (as analysed)

```
mydiary/
├── README.md              ProjectHub docs: test accounts, env vars, API table
├── .gitignore             ignores .env, .env.*, node_modules, dist, backend/bin
├── backend/
│   ├── main.go            wiring: repository -> service -> controller -> router; graceful shutdown
│   ├── go.mod / go.sum    module qt-devops-go-mongo/backend, go 1.23.0
│   ├── .env.example       every backend variable with comments
│   └── internal/          apperror config controller database dto middleware models repository router service cache
└── frontend/
    ├── package.json       scripts: dev, build (vite build), preview. Node 20+ per README
    ├── package-lock.json  locked dependency tree (npm ci)
    ├── vite.config.js     dev proxy /api -> :8080
    ├── index.html         SPA shell (title "ProjectHub")
    ├── .env.example       VITE_API_URL=/api (build-time)
    └── src/               main.jsx (BrowserRouter), App.jsx (routes), api.js (fetch wrapper), auth.jsx, pages/, components/
```

No tests exist (no `*_test.go`, no frontend test script). The `iac/` directory that was nested in the clone is not part of the app (it held Terraform drafts) and is not copied.

## 3. Backend (Go API)

### 3.1 Build and runtime

- Language and tools: Go 1.23 (`go.mod` says `go 1.23.0`). Build with `CGO_ENABLED=0 go build` (README). No CGO, so the binary runs on a minimal base image.
- Listens on `PORT` (default `8080`). Gin mode from `GIN_MODE` (`debug` by default, `release` recommended).
- Loads `.env` from its working directory if present. Real environment variables take precedence. In containers there is no `.env`, so all config comes from the environment.
- Graceful shutdown on SIGINT/SIGTERM with a 10 s timeout. Good for `docker stop` and pod termination.
- Startup order: connect to MongoDB (retries up to `MONGO_CONNECT_TIMEOUT`, default 30 s), ensure indexes, connect to Valkey (optional, background reconnect), seed on first start (if enabled and the users collection is empty), then serve.

### 3.2 Environment variables (from `backend/.env.example` and `config.go`)

| Variable | Default | Required | Notes |
|---|---|---|---|
| `PORT` | `8080` | no | HTTP listen port |
| `MONGO_URI` | `mongodb://localhost:27017` | yes in practice | Compose: `mongodb://user:pass@mongodb:27017/?authSource=admin` |
| `MONGO_DB` | `projecthub` | no | Database name |
| `MONGO_CONNECT_TIMEOUT` | `30s` | no | Go duration |
| `JWT_SECRET` | none | **yes, >= 32 chars** | Process exits at start if shorter |
| `JWT_EXPIRES_IN` | `24h` | no | Token lifetime |
| `CORS_ORIGINS` | `http://localhost:5173` | no | Not needed when NGINX serves both on one origin |
| `SEED_ENABLED` | `true` | no | Creates test accounts and a sample project on empty DB |
| `CACHE_ENABLED` | `true` | no | `false` disables Valkey entirely |
| `VALKEY_ADDR` | `localhost:6379` | no | host:port |
| `VALKEY_PASSWORD` | empty | no (but recommended) | Sent with AUTH |
| `VALKEY_DB` | `0` | no | |
| `CACHE_STATS_TTL` | `2m` | no | Dashboard cache lifetime |
| `CACHE_USER_TTL` | `1m` | no | Authenticated user cache lifetime |
| `GIN_MODE` | `debug` | no | Use `release` |

Frontend build-time variable: `VITE_API_URL` (default `/api`). It is compiled into the JavaScript bundle, so changing it needs a rebuild.

### 3.3 Authentication and authorization

- Register: `POST /api/auth/register` with `{name, email, password}`. Name 2 to 80 chars, password 8 to 72 chars (bcrypt limit). New accounts always get role `member`. Returns `201` with `{token, expiresIn, user}`.
- Login: `POST /api/auth/login` returns `200` with the same body. Wrong email or password returns `401` with one generic message.
- Tokens: HS256 JWT, issuer `projecthub-api`, subject = user ObjectId, claim `role`, signed with `JWT_SECRET`. Validation is strict: only HS256, issuer checked, strict base64 decoding.
- Each request reloads the user (Valkey cache first, then MongoDB), so role changes and deletions take effect immediately.
- Roles: `admin` sees and manages everything; `manager` creates projects and manages ones they own; `member` sees only projects they own or belong to.
- Project visibility (`service/authz.go`): viewable if admin, owner, or member. A project the caller cannot see returns `404`, not `403`, so existence is not leaked. This is the "users only see their own data" rule that must be tested.

### 3.4 API routes (all under `/api`)

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/health` | none | `200` `{status:"ok",database:"up",cache:"up|down|disabled"}` or `503` `{status:"error",database:"down",...}` |
| POST | `/auth/register` | none | 201 |
| POST | `/auth/login` | none | 200 |
| GET | `/auth/me` | token | `{user}` |
| GET | `/stats` | token | Dashboard figures for the caller's projects |
| GET | `/users` | admin, manager | |
| PATCH | `/users/:id/role` | admin | |
| DELETE | `/users/:id` | admin | |
| GET | `/projects` | token | Admin: all. Others: owned or joined |
| POST | `/projects` | admin, manager | |
| GET | `/projects/:id` | visible team | 404 if not visible |
| PUT | `/projects/:id` | owner or admin | Partial update, can transfer ownership |
| DELETE | `/projects/:id` | owner or admin | Also deletes its tasks |
| GET | `/projects/:id/tasks` | visible team | |
| POST | `/projects/:id/tasks` | visible team | |
| PATCH | `/tasks/:id` | owner or admin; assignee may change status only | |
| DELETE | `/tasks/:id` | owner or admin | |

Unknown routes return `404` `{"error":"route not found"}`. Errors are JSON `{"error": "..."}`. Internal errors are logged and returned as a generic `500`.

### 3.5 Data model (MongoDB)

- `users`: `_id`, `name`, `email` (unique index), `passwordHash` (bcrypt, never returned), `role`, `createdAt`.
- `projects`: `_id`, `name`, `description`, `status` (planned|active|completed), `ownerId` (index), `memberIds` (index), `createdAt`, `updatedAt`.
- `tasks`: `_id`, `projectId` (index), `title`, `description`, `status` (todo|in_progress|done), `priority` (low|medium|high), `assigneeId` (index), `dueDate`, `createdBy`, `createdAt`, `updatedAt`.

Indexes are created by the API at every start (`EnsureIndexes`), so no migration tooling is needed.

### 3.6 Cache (Valkey) and graceful degradation

- Keys are prefixed `projecthub:`. Uses JSON values, short TTLs, and version counters for dashboard invalidation.
- Every cache operation fails open. If Valkey is down, reads go to MongoDB and writes are skipped. The API keeps serving.
- `/api/health` reports `cache: "down"` when Valkey is unreachable, but `status` stays `"ok"` as long as MongoDB answers. This is exactly the behaviour the brief's Redis-down test expects.
- Valkey needs no persistence: it holds only rebuildable data. So the Valkey container gets no volume.

### 3.7 Seed (test accounts)

Created by `main.go` on the first start only, when the `users` collection is empty. Idempotent: fixed ObjectId for the sample project, duplicate-key handling for concurrent replicas.

| Role | Email | Password |
|---|---|---|
| admin | `admin@qt.rw` | `Admin@123` |
| manager | `manager@qt.rw` | `Manager@123` |
| member | `member@qt.rw` | `Member@123` |

Also creates project "QT Platform Migration" owned by the manager with the member as a team member, plus four tasks. The README says to set `SEED_ENABLED=false` outside the exam. The brief requires test accounts for examiners, so the exam deployments keep it `true`. This is a decision (see DECISIONS.md D-APP-2).

## 4. Frontend (React SPA)

- Build: `npm ci` then `npm run build` (`vite build`) produces `dist/`: `index.html` plus hashed assets under `assets/`. Node 20+ required by the README. Vite 5.4 needs Node 18+.
- Routing: `BrowserRouter` with client-side routes `/login`, `/register`, `/`, `/projects`, `/projects/:id`, `/users` (admin only). Any unknown path must return `index.html`, so the static server needs an SPA fallback (`try_files $uri /index.html`).
- API calls: `src/api.js` uses `fetch(BASE + path)` where `BASE` is `VITE_API_URL` (default `/api`). Same-origin, so no CORS is needed behind NGINX.
- Auth: JWT stored in `localStorage` under `token`. Sent as `Authorization: Bearer`. On a 401 the token is cleared and the user is logged out.
- Calls used by the UI: `/auth/login`, `/auth/register`, `/auth/me`, `/stats`, `/projects` (GET, POST), `/projects/:id` (GET, PUT, DELETE), `/projects/:id/tasks` (GET, POST), `/tasks/:id` (PATCH, DELETE), `/users` (GET), `/users/:id/role`, `/users/:id`.
- Dev server: port 5173 with `/api` proxied to `http://localhost:8080` (`API_PROXY_TARGET` override). Not used in containers.

## 5. Brief vs reality: decisions needed

| Brief item | Reality | Proposed handling |
|---|---|---|
| Next.js 14 `nextjs` service on port 3000 | Vite static SPA | Service `frontend`: static build served by an unprivileged NGINX on 8080. No Node runtime is needed at run time. |
| Spring Boot `springboot` service on 8080 | Go API on 8080 | Service `api`. Same port, same `/api` prefix, so the nginx routing rule from the brief still holds. |
| PostgreSQL 16 named volume | MongoDB 7 | Service `mongodb` (official `mongo:7.0.14`), named volume `mongo-data` at `/data/db`, no host port. |
| Redis, password required | Valkey 8, optional cache | Service `valkey` (official `valkey/valkey:8.1.12-alpine`), password required, no volume, no host port. |
| `/actuator/health` | Not present | Not implemented. Only `/api/health` exists. Health checks use `/api/health`. |
| Diary entries, mood, tags, search, streak stats | Projects and tasks, no search | Functional test uses projects and tasks. Search is not implemented; see section 7. |
| Redis/DB persistence rationale | Valkey holds only cache | Unchanged: no persistent volume for the cache. |
| Java 21 / Maven | Go 1.23 | Build stage `golang:1.23.12-alpine3.21`. |
| `Spring profile` ConfigMap | None | ConfigMap holds the Go API environment variables instead. |

## 6. Proposed container architecture

### 6.1 Services (same names in Compose and Kubernetes so `nginx.conf` is shared)

| Service | Image (Docker Hub) | Listens | Exposed to host | Volume | Role |
|---|---|---|---|---|---|
| `nginx` | `nginx:1.27.5-alpine` (official) | 80 | **80** (Compose) / **30080** NodePort (K8s) | none; `nginx.conf` mounted read-only | Entry point. `/api/` to `api:8080`, `/` to `frontend:8080` |
| `frontend` | `<user>/projecthub-frontend:<tag>` built from `nginxinc/nginx-unprivileged:1.27.5-alpine` | 8080 (non-root) | no | none | Serves `dist/` with SPA fallback |
| `api` | `<user>/projecthub-api:<tag>` built from `alpine:3.21.10` runtime | 8080 (non-root, uid 10001) | no | none | Go API |
| `mongodb` | `mongo:7.0.14` (official) | 27017 | **no** | `mongo-data` to `/data/db` | Users, projects, tasks |
| `valkey` | `valkey/valkey:8.1.12-alpine` (official) | 6379 | **no** | none (cache only) | Optional cache, password required |

Brief-required names differ: `nextjs` becomes `frontend`, `springboot` becomes `api`, `postgres` becomes `mongodb`, `redis` becomes `valkey`. See DECISIONS.md D-APP-1.

### 6.2 Network flow

```
client ──HTTP :80──> nginx ──/──────> frontend:8080  (static files, SPA fallback)
                         └─/api/───> api:8080 ──> mongodb:27017   (required)
                                              └─> valkey:6379     (optional, fail-open)
```

### 6.3 Environment variables per service

- `api`: `PORT=8080`, `GIN_MODE=release`, `MONGO_URI` (secret: contains the Mongo password), `MONGO_DB=projecthub`, `MONGO_CONNECT_TIMEOUT=60s`, `JWT_SECRET` (secret, >= 32 chars), `JWT_EXPIRES_IN=24h`, `SEED_ENABLED=true`, `CACHE_ENABLED=true`, `VALKEY_ADDR=valkey:6379`, `VALKEY_PASSWORD` (secret), `VALKEY_DB=0`, `CACHE_STATS_TTL=2m`, `CACHE_USER_TTL=1m`, `CORS_ORIGINS` left at default (same origin).
- `frontend` (build arg): `VITE_API_URL=/api`.
- `mongodb`: `MONGO_INITDB_ROOT_USERNAME`, `MONGO_INITDB_ROOT_PASSWORD` (secret).
- `valkey`: password via command line `--requirepass` from `VALKEY_PASSWORD`.
- `nginx`: none.

### 6.4 Health checks

- `api`: `GET /api/health` returns 200 only while MongoDB answers.
- `frontend`: `GET /` returns 200.
- `nginx`: `GET /` returns 200. This proves nginx and its frontend upstream.
- `mongodb`: `mongosh`/`mongo` ping, or a TCP check if the shell is not in the image.
- `valkey`: `valkey-cli ping` returns `PONG` (auth via `REDISCLI_AUTH`).

## 7. Mapping the brief's functional test to this app

| Brief requirement | Test in this app |
|---|---|
| Register | `POST /api/auth/register` returns 201 with a token |
| Login | `POST /api/auth/login` returns 200 with a token |
| Create a diary entry | Create a project (manager) and a task inside it (member or manager) |
| Search entries | **Not implemented.** Verify list endpoints instead: `GET /api/projects`, `GET /api/projects/:id/tasks`. Raise with the user: see DECISIONS.md D-APP-3. |
| Users only see their own data | A new member registered via the API gets `[]` from `GET /api/projects`. Requesting the seeded project by id returns 404. The task list of another user's project returns 404. |

## 8. Known gaps and risks in the code (not fixed: app code is out of scope)

- No automated tests in the repo.
- README suggests `SEED_ENABLED=false` outside the exam. Exam deployments keep it `true` so examiners have accounts.
- `CORS_ORIGINS` default is `http://localhost:5173`. Same-origin NGINX makes CORS unnecessary.
- JWT is stored in `localStorage` (XSS-readable). Acceptable for the exam; note it in the README.
- Mongo has no authentication in the upstream `.env.example`. The compose and K8s setups add root credentials and put them in the URI.
- `GIN_MODE` defaults to `debug` in code, so the containers set `release`.
