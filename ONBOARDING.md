# Cómo empezar — Maminco Infra

Guía de onboarding en español para levantar y desplegar la infraestructura de
**Maminco** (POS de restaurante). Este repositorio **solo contiene
infraestructura** (Docker, nginx, Terraform, CI y documentación); no hay código
de aplicación aquí.

## 1. ¿Qué hay en Maminco?

Cuatro servicios en repositorios git separados:

| Repo | Qué es | Puerto (interno) |
| ---- | ------ | ---------------- |
| `maminco-backend` | API NestJS + Prisma + socket.io | 3000 |
| `maminco-frontend` | App Next.js 16 (App Router) | 3001 |
| `maminco-ai` | Servicio ML en FastAPI | 8000 |
| `maminco-mobile` | App Expo/EAS | — (no se dockeriza) |

Todo corre en **un solo servidor EC2 pequeño** con Docker Compose, y nginx
publica todo en el puerto **80**.

## 2. Estructura de carpetas (importante)

Los repos deben estar **uno al lado del otro**:

```
development/
├── maminco-infra/       ← estás aquí
├── maminco-backend/
├── maminco-frontend/
└── maminco-ai/
```

El `docker-compose.yml` construye cada app con `context: ../maminco-<app>` y el
Dockerfile que vive en este repo (`docker/`), de modo que **no se toca el código
de las apps**.

## 3. Requisitos

- Docker Engine + Docker Compose v2 (`docker compose version`)
- (Para AWS) Terraform ≥ 1.5 y credenciales de AWS configuradas (`aws configure`)

## 4. Levantar todo en local

```bash
cp .env.example .env      # 1. Copia el archivo de variables
vi .env                   # 2. Cambia JWT_SECRET e INTERNAL_SERVICE_TOKEN
make up                   # 3. Construye y arranca todo
make ps                   # 4. Ver estado
make logs SERVICE=backend # 5. Ver logs de un servicio
```

Abre <http://localhost>. El primer usuario administrador se crea llamando
`POST /api/auth/register-first-admin` (solo funciona mientras no exista ningún
usuario).

### Comandos útiles del Makefile

| Comando | Qué hace |
| ------- | -------- |
| `make up` | Levanta la pila en segundo plano |
| `make down` | Detiene la pila (conserva la base de datos) |
| `make logs` | Sigue los logs (`SERVICE=backend` para uno solo) |
| `make ps` | Muestra el estado de los contenedores |
| `make rebuild` | Reconstruye imágenes y recrea contenedores |
| `make seed` | Ejecuta el seed de Prisma en el backend |
| `make tf-up` | Crea/actualiza la infraestructura en AWS |
| `make tf-destroy` | Destruye toda la infraestructura |
| `make deploy` | Reconstruye y levanta con verificación de salud |

## 5. Variables de entorno (lo mínimo)

- `JWT_SECRET`: **obligatorio**, mínimo 32 caracteres.
  Genéralo con `openssl rand -base64 48`.
- `INTERNAL_SERVICE_TOKEN`: secreto compartido entre backend e IA.
  ⚠️ **Debe ser idéntico** al `AI_INTERNAL_SERVICE_TOKEN` de la IA. En Compose
  se deriva solo desde `INTERNAL_SERVICE_TOKEN`.
- `NEXT_PUBLIC_API_URL` / `NEXT_PUBLIC_SOCKET_URL`: solo el **origen**, sin
  `/api` y sin barra final. Se compilan en el bundle, así que si cambian hay
  que reconstruir el frontend.

## 6. Desplegar en AWS (resumen)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars          # region, key_name, allowed_ssh_cidr (¡tu IP!)
terraform init
terraform apply
```

Luego entra al servidor (SSH o SSM) y:

```bash
cd /opt/maminco/maminco-infra
cp .env.example .env && vi .env
make up
```

La guía completa, con rollback, está en [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## 7. Actualizar un servicio

```bash
./deploy/ec2-update.sh backend    # o frontend / ai / all
```

Hace `git pull` del repo correspondiente y reconstruye solo ese servicio.

## 8. Problemas frecuentes

- **La web no carga / error de red:** revisa `NEXT_PUBLIC_API_URL`. Debe ser el
  origen público (p. ej. `http://<ip-ec2>`), no `localhost`.
- **Backend no arranca:** casi siempre falta `JWT_SECRET` (mínimo 32 caracteres)
  o la base de datos aún no está lista.
- **401/403 entre backend e IA:** los tokens internos no coinciden.
- **La IA no conecta a la base:** revisa `AI_DATABASE_URL`.
- **Docker "permission denied":** cierra sesión y vuelve a entrar (grupo docker)
  o usa `sudo docker compose`.

## 9. Antes de hacer commit

```bash
docker compose config --quiet
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
```

Recuerda: **un commit por repositorio**; no mezcles cambios de apps con infra.
