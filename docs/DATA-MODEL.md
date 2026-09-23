# Data model

Derived from `maminco-backend/prisma/schema.prisma` (PostgreSQL). All ids are
UUID strings unless noted. Money is `Decimal(10,2)` in **Bolivianos (Bs)**.
Most core tables support soft deletes via `deletedAt`.

## ER diagram

```mermaid
erDiagram
    User {
        uuid id PK
        string email UK
        string password
        string name
        enum role
        boolean isActive
        datetime createdAt
        datetime updatedAt
        datetime deletedAt
        uuid personalId FK,UK
    }

    PersonalType {
        uuid id PK
        string name UK
        string description
        datetime deletedAt
    }

    Personal {
        uuid id PK
        string name
        string phone
        string address
        datetime hireDate
        boolean isActive
        datetime deletedAt
        uuid personalTypeId FK
    }

    StaffPayment {
        uuid id PK
        decimal amount
        datetime paymentDate
        string notes
        uuid staffId FK
        uuid createdById FK
    }

    Category {
        uuid id PK
        string name UK
        string description
        boolean isActive
        datetime deletedAt
    }

    StockGroup {
        uuid id PK
        string name UK
        string description
        int stock
        boolean isActive
        datetime deletedAt
    }

    Product {
        uuid id PK
        string name
        string description
        decimal price
        boolean isAvailable
        boolean isActive
        int individualStock
        datetime deletedAt
        uuid categoryId FK
        uuid stockGroupId FK
    }

    Area {
        uuid id PK
        string name UK
        string description
        boolean isVirtual
        boolean isActive
        datetime deletedAt
    }

    Table {
        uuid id PK
        int number
        enum status
        boolean isActive
        datetime deletedAt
        uuid areaId FK
    }

    Order {
        uuid id PK
        string orderNumber UK
        enum status
        string serviceType
        decimal subtotal
        decimal discountAmount
        decimal tipAmount
        decimal total
        datetime createdAt
        datetime closedAt
        datetime deletedAt
        uuid tableId FK
        uuid createdById FK
        uuid attendedById FK
        uuid closedById FK
    }

    OrderItem {
        uuid id PK
        int quantity
        decimal unitPrice
        decimal discountAmount
        decimal subtotal
        string notes
        uuid productId FK
        uuid orderId FK
        uuid addedById FK
    }

    PaymentMethod {
        uuid id PK
        string name UK
        string code UK
        string description
        boolean isActive
        datetime deletedAt
    }

    CashDenomination {
        uuid id PK
        decimal value
        string type
        int quantity
        boolean isActive
    }

    Payment {
        uuid id PK
        decimal amountReceived
        decimal amountApplied
        decimal changeAmount
        decimal tipAmount
        uuid orderId FK
        uuid paymentMethodId FK
        uuid createdById FK
    }

    AuditLog {
        uuid id PK
        enum action
        string tableName
        string recordId
        json oldValues
        json newValues
        string description
        datetime createdAt
        uuid userId FK
        uuid orderId FK
    }

    OrderHistory {
        uuid id PK
        string action
        string description
        json metadata
        datetime createdAt
        uuid orderId FK
        uuid userId FK
    }

    OrderItemHistory {
        uuid id PK
        string action
        int quantity
        decimal unitPrice
        datetime createdAt
        uuid productId FK
        string orderId
    }

    DailyMetrics {
        uuid id PK
        date date UK
        decimal totalSales
        int totalOrders
        decimal totalDiscount
        decimal totalTips
        decimal averageOrderValue
        int mesaOrders
        int deliveryOrders
        int recogerOrders
        decimal cashPayments
        decimal cardPayments
        decimal transferPayments
        decimal totalStaffPayments
    }

    ExpenseCategory {
        uuid id PK
        string name UK
        string description
        boolean isActive
        datetime deletedAt
    }

    Expense {
        uuid id PK
        string description
        decimal amount
        datetime expenseDate
        string receipt
        datetime deletedAt
        uuid categoryId FK
    }

    %% Catalog & staffing
    PersonalType ||--o{ Personal : "classifies"
    Personal    ||--o| User : "optional account"
    Personal    ||--o{ StaffPayment : "receives"
    User        ||--o{ StaffPayment : "records"

    %% Catalog
    Category    ||--o{ Product : "groups"
    StockGroup  ||--o{ Product : "shared stock"
    Product     ||--o{ OrderItem : "sold as"
    Product     ||--o{ OrderItemHistory : "logged in"

    %% Tables
    Area        ||--o{ Table : "contains"
    Table       ||--o{ Order : "hosts"

    %% Orders
    User        ||--o{ Order : "createdBy"
    User        ||--o{ Order : "attendedBy"
    User        ||--o{ Order : "closedBy"
    Order       ||--o{ OrderItem : "contains"
    User        ||--o{ OrderItem : "addedBy"

    %% Payments
    Order         ||--o{ Payment : "settled by"
    PaymentMethod ||--o{ Payment : "uses"
    User          ||--o{ Payment : "createdBy"

    %% Audit & history
    User  ||--o{ AuditLog : "performed"
    Order ||--o{ AuditLog : "affects"
    Order ||--o{ OrderHistory : "tracks"
    User  ||--o{ OrderHistory : "performed"

    %% Expenses
    ExpenseCategory ||--o{ Expense : "classifies"
```

## Enums

| Enum | Values |
| ---- | ------ |
| `UserRole` | `ADMINISTRATOR`, `MANAGER`, `CASHIER`, `WAITER` |
| `OrderStatus` | `DRAFT`, `CLOSED`, `CANCELLED` |
| `TableStatus` | `AVAILABLE`, `OCCUPIED`, `RESERVED` |
| `AuditAction` | `CREATE`, `UPDATE`, `DELETE`, `PAYMENT`, `CLOSE_ORDER`, `CANCEL_ORDER` |

## Table notes

- **`users`** — auth identity. `personalId` optionally links a system user to a
  staff record. Role drives the backend's `@Roles(...)` guards.
- **`personal` / `personal_types`** — HR records; `personal_types` are
  customizable (CASHIER, WAITER, COCINERO…). **`staff_payments`** records wages
  paid, with the paying user for audit.
- **`categories`, `stock_groups`, `products`** — menu catalog. A product belongs
  to one category, and *optionally* to a stock group (shared inventory) or has
  its own `individualStock`.
- **`areas` / `tables`** — `areas` may be virtual (DELIVERY, RECOGER), in which
  case tables can have `number = 0`. `Table` is unique per `(areaId, number)`.
- **`orders`** — the sale header. `serviceType` mirrors the area name. Amounts:
  `total = subtotal - discountAmount + tipAmount`. Three user references track
  who created / attended / closed it.
- **`order_items`** — line items, `subtotal = quantity * unitPrice - discountAmount`,
  plus free-text `notes` (e.g. "sin cebolla") and `addedById` for audit.
  Cascade-deleted with the order.
- **`payments`** — one order can have several payments (split payments).
  `amountReceived`, `amountApplied`, optional `changeAmount` (cash only) and
  `tipAmount`.
- **`payment_methods`** — seeded as EFECTIVO/CASH, TRANSFERENCIA/TRANSFER,
  TARJETA/CARD (see `prisma/seed.ts`).
- **`cash_denominations`** — Boliviano coins/bills (1,2,5,10 coins; 20,50,100,200
  bills), unique per `(value, type)`, with a running `quantity` for the drawer.
- **`audit_logs`** — generic JSON before/after snapshots keyed by
  `(tableName, recordId)`, optionally linked to an order.
- **`order_histories` / `order_item_histories`** — human-readable change logs
  for an order and its items.
- **`daily_metrics`** — pre-aggregated BI rollup, one row per `date` (unique).
- **`expenses` / `expense_categories`** — operating expenses with an optional
  receipt reference.

## Indexes (highlights)

`orders(status, tableId, createdById, attendedById, closedById, createdAt, serviceType)`,
`products(categoryId, stockGroupId, isAvailable)`, `payments(orderId)`,
`tables(status)`, `audit_logs(userId, orderId, [tableName, recordId], createdAt)`.

## Schema lifecycle

There are **no committed Prisma migrations** yet. Deployments apply the schema
with `npx prisma db push` (see `docker-compose.yml`), then run the idempotent
`npx prisma db seed`. If migrations are added later, switch the backend boot
command to `npx prisma migrate deploy`.
