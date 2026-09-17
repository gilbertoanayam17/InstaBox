# InstaBox

Backend de una estación de fotos para bodas y eventos sociales. Los invitados suben una foto con
un mensaje para los festejados; el servidor guarda una versión reducida de la foto, compone una
polaroid con el mensaje escrito abajo y registra a qué evento pertenece cada foto. Al terminar el
evento se descarga un `.zip` con todas las polaroids listas para imprimir.

Práctica 1 de Desarrollo en la Nube (ITESO).

## Arquitectura

- **EC2** corre el backend (Express + TypeScript).
- **S3** guarda las fotos: la reducida de 128x128 en `pictures/` y la polaroid en `polaroids/`.
- **RDS (PostgreSQL)** guarda la metadata en las tablas `events` y `photos`, relacionadas por `event_id`.
- **Secrets Manager** guarda los datos de la conexión a RDS (usuario, contraseña, host y base).
  La app los lee al arrancar con el rol del instance profile `LabInstanceProfile`; no hay
  credenciales en el código ni en el `.env`, que solo lleva puerto, región, bucket y el nombre
  del secret.

## Endpoints

| Método | Ruta                 | Qué recibe                                          | Qué regresa                           |
| ------ | -------------------- | --------------------------------------------------- | ------------------------------------- |
| POST   | `/events`            | JSON: `client_name`, `event_type`, `event_date`     | `201` con el `event_id` (UUID)        |
| POST   | `/upload`            | form-data: `photo` (archivo), `event_id`, `message` | `201` con las rutas en S3             |
| GET    | `/events/{event_id}` | —                                                   | `200` con la metadata y `photo_count` |
| POST   | `/finish`            | JSON: `event_id`                                    | `200` con el `.zip` de las polaroids  |
| GET    | `/health`            | —                                                   | `OK`, para revisar que el server vive |

`POST /finish` también borra de S3 las fotos originales del evento y lo marca como `finished`.

## Tablas

```sql
events (event_id UUID PK, client_name, event_type, event_date, status, created_at)
photos (photo_id UUID PK, event_id UUID FK -> events, message, picture_key, polaroid_key, created_at)
```

Se crean solas al arrancar el servidor (`src/db.ts`).

## Cómo correrlo

```bash
npm install
cp .env.example .env   # ajustar región, bucket y nombre del secret
npm run dev            # desarrollo
```

En la EC2:

```bash
npm install
npm run build
npm start
```

`sharp` dibuja el mensaje con una fuente del sistema y la imagen de Ubuntu viene sin fuentes, así
que en la instancia hay que instalarlas o el texto de la polaroid sale vacío:

```bash
sudo apt install -y fonts-dejavu-core
```

## Probarlo en Postman

1. `POST /events` con JSON: `{ "client_name": "Ana y Luis", "event_type": "boda", "event_date": "2026-09-20" }`
2. `POST /upload` en **form-data**: `photo` (tipo File), `event_id` y `message` (tipo Text).
3. `GET /events/{event_id}` para ver la metadata y el número de fotos.
4. `POST /finish` con `{ "event_id": "..." }`, usando **Send and Download** para guardar el `.zip`.

## Archivos

```
src/
  index.ts                     express, las rutas y el arranque
  db.ts                        lee el secret, conecta a RDS y crea las tablas
  s3.ts                        cliente de S3
  polaroid.ts                  reduce a 128x128 y compone la polaroid
  controllers/
    events.controller.ts       POST /events y GET /events/:event_id
    photos.controller.ts       POST /upload y POST /finish
  types/http-status.ts         códigos de respuesta
```
