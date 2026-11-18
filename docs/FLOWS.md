# Flows

End-to-end sequence diagrams for the main Maminco interactions. Socket event
names are illustrative — check `maminco-backend/src/orders/orders.gateway.ts`
and `.../payments/payments.gateway.ts` for the exact strings.

Participants:

- **Browser** — POS terminal or admin UI (React client)
- **nginx** — reverse proxy, TLS on 443 (HTTP only in dev)
- **Frontend** — Next.js server (SSR + `proxy.ts`)
- **Backend** — NestJS API (`/api/*`) + socket.io gateway
- **Postgres** — single database
- **AI** — FastAPI forecasting service

---

## 1. Login

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant B as Browser
    participant N as nginx
    participant BE as Backend
    participant PG as Postgres

    U->>B: Enter email + password
    B->>N: POST /api/auth/login
    N->>BE: proxy /api -> backend:3000
    BE->>PG: SELECT user by email (active)
    PG-->>BE: user row (bcrypt hash)
    BE->>BE: bcrypt.compare(password, hash)
    alt valid credentials
        BE->>BE: sign JWT {sub, role, ...}
        BE-->>N: 200 { token, user }
        N-->>B: 200 { token, user }
        B->>B: persist zustand "maminco-auth" (localStorage)
        B->>B: set `token` cookie (for middleware)
        B->>N: GET /dashboard
        N->>B: serves Frontend
        B->>B: middleware sees token cookie -> allow
    else invalid
        BE-->>N: 401 Unauthorized
        N-->>B: 401
        B-->>U: "Credenciales inválidas"
    end
```

Protected navigations (admin + POS prefixes) are guarded by `proxy.ts`,
which reads the `token` cookie and redirects to `/auth/login?from=...` when it
is missing. Authorization by role is enforced server-side with `@Roles(...)`.

---

## 2. Create order + add items

```mermaid
sequenceDiagram
    autonumber
    actor W as Waiter
    participant B as Browser
    participant N as nginx
    participant BE as Backend
    participant PG as Postgres
    participant GW as Socket.IO gateway

    W->>B: Select table, "New order"
    B->>N: POST /api/orders {tableId}
    N->>BE: proxy (Authorization: Bearer <jwt>)
    BE->>BE: JWT guard + role check
    BE->>PG: create Order (status=DRAFT, orderNumber, createdById)
    BE->>PG: update Table.status = OCCUPIED
    BE->>PG: insert OrderHistory "Creó la orden"
    PG-->>BE: order
    BE->>GW: emit "order:created" / "table:updated"
    GW-->>B: WebSocket push
    BE-->>B: 201 { order }

    loop Add each product
        W->>B: Tap product (qty, notes)
        B->>N: POST /api/orders/:id/items {productId, quantity}
        N->>BE: proxy
        BE->>PG: read Product.price
        BE->>PG: insert OrderItem (unitPrice, subtotal, addedById)
        BE->>PG: recompute Order.subtotal/total, insert OrderItemHistory
        BE->>GW: emit "order:updated"
        GW-->>B: push updated totals
        BE-->>B: 201 { item, order }
    end
```

All monetary values are snapshotted at sale time (`unitPrice`), and
`subtotal = quantity * unitPrice - discountAmount`. The order remains `DRAFT`
until payment closes it.

---

## 3. Payment + close order

```mermaid
sequenceDiagram
    autonumber
    actor C as Cashier
    participant B as Browser
    participant N as nginx
    participant BE as Backend
    participant PG as Postgres
    participant GW as Socket.IO gateway

    C->>B: Choose payment method + amount
    B->>N: POST /api/payments {orderId, paymentMethodId, amountReceived, tipAmount}
    N->>BE: proxy (Bearer jwt)
    BE->>PG: insert Payment (amountApplied, changeAmount, createdById)
    BE->>PG: insert AuditLog (action=PAYMENT)

    alt order fully covered
        BE->>PG: update Order { status=CLOSED, closedAt, closedById, tipAmount }
        BE->>PG: update Table.status = AVAILABLE
        BE->>PG: insert OrderHistory "Cerró la orden"
        BE->>PG: upsert DailyMetrics
        BE->>PG: insert AuditLog (action=CLOSE_ORDER)
        BE->>GW: emit "order:closed", "table:updated", "payment:created"
        GW-->>B: push to all terminals
        BE-->>B: 201 { payment, order(status=CLOSED) }
    else partial payment
        BE->>GW: emit "payment:created"
        BE-->>B: 201 { payment, order(status=DRAFT, remaining) }
    end
```

Split payments are supported: multiple `Payment` rows per order until the total
is covered. Cash change is only computed for the cash method.

---

## 4. Realtime table updates

```mermaid
sequenceDiagram
    autonumber
    participant B1 as POS terminal A
    participant B2 as POS terminal B
    participant N as nginx
    participant GW as Backend socket.io
    participant BE as Backend REST
    participant PG as Postgres

    B2->>N: GET /socket.io/?transport=websocket (Upgrade)
    N->>GW: proxy with Upgrade headers
    GW-->>B2: 101 Switching Protocols (namespace connected)

    B1->>N: POST /api/orders (occupy table 7)
    N->>BE: proxy
    BE->>PG: Table 7 -> OCCUPIED
    BE->>GW: emit "table:updated" {id:7, status:OCCUPIED}
    GW-->>B1: push
    GW-->>B2: push (broadcast to room)
    B2->>B2: invalidate table query -> UI turns red
```

nginx must forward the WebSocket upgrade for `/socket.io/` (see
`nginx/default.conf`); the frontend subscribes via
`lib/utils/socket.ts` / `hooks/useOrderSocket.ts` using `NEXT_PUBLIC_SOCKET_URL`.

---

## 5. Forecast request (backend → AI)

```mermaid
sequenceDiagram
    autonumber
    actor G as Manager
    participant B as Browser
    participant N as nginx
    participant BE as Backend
    participant AI as AI (FastAPI)
    participant PG as Postgres

    G->>B: Open "Forecast" / reports
    B->>N: GET /api/ai/forecast
    N->>BE: proxy (Bearer jwt, role=MANAGER/ADMIN)
    BE->>BE: attach X-Internal-Service-Token: INTERNAL_SERVICE_TOKEN
    BE->>AI: POST http://ai:8000/forecast (AI_SERVICE_URL)
    AI->>AI: verify AI_INTERNAL_SERVICE_TOKEN matches
    AI->>PG: query daily_metrics / orders (AI_DATABASE_URL)
    PG-->>AI: historical aggregates
    AI->>AI: run model -> predictions
    AI-->>BE: 200 { forecast: [...] }
    BE-->>B: 200 { forecast: [...] }
    B-->>G: Render chart
```

The backend and AI must share the **same** secret: backend
`INTERNAL_SERVICE_TOKEN` **==** ai `AI_INTERNAL_SERVICE_TOKEN`. The AI service
reads the same Postgres database through `AI_DATABASE_URL`.
