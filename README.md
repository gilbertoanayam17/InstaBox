# InstaBox

Backend de una estación de fotos para bodas y eventos sociales. Los invitados suben una foto con
un mensaje para los festejados; el servidor guarda una versión reducida de la foto, compone una
polaroid con el mensaje escrito abajo y registra a qué evento pertenece cada foto. Al terminar el
evento se descarga un `.zip` con todas las polaroids listas para imprimir, y las fotos originales
se eliminan.

Práctica 1 de Desarrollo en la Nube (ITESO).

## Arquitectura

```
   Postman ──── HTTP :3000 ────► EC2  (Ubuntu 24.04 · Node 22 · pm2)
                                  │    instance profile: LabInstanceProfile
                                  │
           ┌──────────────────────┼──────────────────────┐
           ▼                      ▼                      ▼
   Secrets Manager          RDS PostgreSQL              S3
   instabox/rds             events · photos       pictures/ · polaroids/
   usuario y contraseña     metadata               fotos reducidas y polaroids
```

- **EC2** corre el backend. Tiene asignado el instance profile `LabInstanceProfile`, que es lo que
  le permite hablar con los demás servicios **sin credenciales guardadas en la máquina**.
- **S3** guarda las fotos: la reducida de 128×128 en `pictures/` y la polaroid en `polaroids/`.
  Ambas versiones comparten el mismo UUID en el nombre.
- **RDS (PostgreSQL)** guarda la metadata en las tablas `events` y `photos`, relacionadas por
  `event_id`.
- **Secrets Manager** guarda los datos de conexión a la base. La aplicación los lee al arrancar, en
  tiempo de ejecución; en el `.env` solo hay configuración que no sirve para entrar a ningún lado.

## Endpoints

| Método | Ruta                 | Qué recibe                                          | Qué regresa                             |
| ------ | -------------------- | --------------------------------------------------- | --------------------------------------- |
| POST   | `/events`            | JSON: `client_name`, `event_type`, `event_date`     | `201` con el `event_id` (UUID)          |
| POST   | `/upload`            | form-data: `photo` (archivo), `event_id`, `message` | `201` con las rutas en S3               |
| GET    | `/events/{event_id}` | —                                                   | `200` con la metadata y `photo_count`   |
| POST   | `/finish`            | JSON: `event_id`                                    | `200` con el `.zip` de las polaroids    |
| GET    | `/health`            | —                                                   | `OK`, para comprobar que el server vive |

`POST /upload` hace las tres cosas en la misma llamada: reduce la foto y la sube a `pictures/`,
compone la polaroid y la sube a `polaroids/`, y guarda el registro en RDS.

`POST /finish` también borra de S3 las fotos originales del evento y lo marca como `finished`.

## Tablas

```sql
events (event_id UUID PK, client_name, event_type, event_date, status, created_at)
photos (photo_id UUID PK, event_id UUID FK -> events, message, picture_key, polaroid_key, created_at)
```

Se crean solas al arrancar el servidor (`src/db.ts`).

---

# Levantarlo desde cero

## 1. Requisitos en el equipo local

Se requiere una terminal tipo Unix: **Linux, macOS o WSL en Windows**. Los scripts no corren en
PowerShell ni en CMD.

| Herramienta                 | Para qué                                      | Cómo verificar            |
| --------------------------- | --------------------------------------------- | ------------------------- |
| AWS CLI v2                  | crear y borrar los recursos                   | `aws --version`           |
| ssh y scp                   | entrar a la instancia y copiarle el código    | `ssh -V`                  |
| curl, tar, openssl, python3 | descargas, empaquetado, contraseña, leer JSON | vienen en cualquier Linux |
| Postman                     | probar la API                                 | —                         |

Si el AWS CLI no está instalado:

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install
```

> **En WSL:** conviene trabajar desde la terminal de Ubuntu, no desde Git Bash. Y la llave `.pem`
> no debe vivir en `/mnt/c`: ese sistema de archivos ignora `chmod`, la llave queda legible por
> todos y `ssh` la rechaza. Los scripts la guardan en el home de Linux justamente por eso.

## 2. Credenciales de AWS

En el **AWS Learner Lab**: botón **AWS Details** → **AWS CLI: Show**. Copiar el bloque completo y
pegarlo en `~/.aws/credentials`:

```bash
nano ~/.aws/credentials
```

```ini
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

La región se define en `~/.aws/config`:

```ini
[default]
region=us-east-1
output=json
```

⚠️ **Estas credenciales caducan cada 3-4 horas.** Cuando un comando responda `ExpiredToken` hay
que volver al lab y pegarlas de nuevo; no es un problema de configuración del proyecto.

## 3. Los cuatro scripts

```bash
bash preflight.sh    # revisa que no falte nada
bash setup.sh        # crea la infraestructura en AWS  (~10 min)
bash deploy.sh       # sube el código y lo deja corriendo  (~4 min)
bash teardown.sh     # borra todo al terminar
```

Se ejecutan en ese orden, desde la carpeta del proyecto.

> **Finales de línea:** los scripts solo funcionan con finales de línea LF. El archivo
> `.gitattributes` del repositorio lo garantiza al clonar, pero si alguno se edita con un editor
> de Windows y queda en CRLF, bash falla con `$'\r': command not found`. Se corrige con
> `sed -i 's/\r$//' *.sh`.

### `preflight.sh`

No crea nada. Revisa que estén las herramientas, que las credenciales sirvan, que exista una VPC
en la región, e informa el número de cuenta activa. Si algo falla, indica cómo resolverlo.

### `setup.sh`

Crea, en este orden:

1. **Bucket de S3** `instabox-fotos-<cuenta>`. Lleva el número de cuenta porque los nombres de
   bucket son únicos en todo el mundo, y `instabox` a secas seguramente está ocupado.
2. **Security group de la aplicación**, con el 22 abierto solo para la IP pública del equipo y el
   3000 abierto a internet para que Postman pueda entrar.
3. **Security group de la base**, con el 5432 abierto **al security group de la aplicación**, no a
   una IP: solo lo que viva en ese grupo puede hablarle a la base.
4. **DB subnet group** con las subredes de la VPC.
5. **Instancia RDS PostgreSQL** (`db.t3.micro`, sin acceso público), con una contraseña generada
   al vuelo. Este es el paso lento: entre 5 y 10 minutos.
6. **Secret** `instabox/rds` con usuario, contraseña, host, puerto y nombre de la base.
7. **Key pair**, guardado en `~/instabox-key.pem` con permisos `400`.
8. **Instancia EC2** Ubuntu 24.04 `t3.small` con el instance profile `LabInstanceProfile`.

Al terminar deja un archivo `instabox.env` con los identificadores de todo lo creado. Ese archivo
lo lee `deploy.sh` y no debe subirse a git (ya está en el `.gitignore`).

**Se puede volver a ejecutar**: lo que ya existe se reutiliza en vez de duplicarse.

### `deploy.sh`

1. Espera a que la instancia acepte SSH. Esto importa: `sshd` empieza a escuchar antes de que
   `cloud-init` termine de instalar la llave, y en esa ventana las conexiones se cierran solas.
2. Empaqueta el proyecto **sin** `node_modules` (pesa cientos de megas y los binarios de `sharp`
   son los del sistema operativo local, no los de Linux) y lo copia por `scp`.
3. Dentro de la instancia instala Node 22, `fonts-dejavu-core`, `postgresql-client` y el AWS CLI;
   escribe el `.env`; corre `npm install` y `npm run build`.
4. Arranca la aplicación con **pm2**, que la mantiene viva aunque se cierre la sesión SSH.
5. Comprueba desde el equipo local que `/health` responda.

Conviene volver a ejecutarlo cada vez que cambie el código: reemplaza los archivos, recompila y
reinicia el proceso.

> `fonts-dejavu-core` no es opcional. Ubuntu Server viene sin fuentes y `sharp` dibuja el mensaje
> de la polaroid con una fuente del sistema: sin ella, las polaroids salen con el marco pero
> **sin texto**.

### `teardown.sh`

Borra todo en el orden correcto: EC2 → RDS → subnet group → security groups → key pair → secret →
bucket (vaciándolo antes). Al final imprime unas tablas de comprobación que deben salir vacías.

Dos detalles que el orden respeta:

- El **security group de la base va antes** que el de la aplicación, porque su regla del 5432
  apunta al de la aplicación y AWS no deja borrar un grupo mientras otro lo esté referenciando.
- El secret se borra con `--force-delete-without-recovery`. Sin esa bandera, AWS aparta el nombre
  hasta 30 días y no se puede volver a crear uno igual.

## 4. Probar la API

`deploy.sh` imprime la URL al terminar. En Postman se crea un environment con
`base_url = http://<IP-de-la-EC2>:3000` y estas cinco peticiones:

| Petición                               | Body                                                      |
| -------------------------------------- | --------------------------------------------------------- |
| `GET {{base_url}}/health`              | —                                                         |
| `POST {{base_url}}/events`             | raw · JSON con `client_name`, `event_type`, `event_date`  |
| `POST {{base_url}}/upload`             | form-data: `photo` **(tipo File)**, `event_id`, `message` |
| `GET {{base_url}}/events/{{event_id}}` | —                                                         |
| `POST {{base_url}}/finish`             | raw · JSON con `event_id` — usar **Send and Download**    |

En la pestaña **Scripts → Post-response** de `POST /events`, esto guarda el id para las demás
peticiones y evita copiarlo a mano:

```javascript
pm.environment.set('event_id', pm.response.json().event_id);
```

El campo del archivo **debe llamarse `photo`** y tener tipo **File** en el desplegable de
form-data; si queda como Text, el archivo no viaja y la respuesta es un `400`.

## 5. Revisar lo que quedó en AWS

Entrar a la instancia:

```bash
ssh -i ~/instabox-key.pem ubuntu@<IP>
```

Ya dentro, comprobar con qué identidad corre (debe decir `LabInstanceProfile`):

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/info
```

Consultar las tablas, sacando la contraseña del secret sin escribirla en ningún momento:

```bash
SECRET=$(aws secretsmanager get-secret-value --secret-id instabox/rds --query SecretString --output text --region us-east-1)
export PGPASSWORD=$(echo $SECRET | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")
DB_HOST=$(echo $SECRET | python3 -c "import sys,json;print(json.load(sys.stdin)['host'])")

psql -h $DB_HOST -U postgres -d instabox -c "\dt"
psql -h $DB_HOST -U postgres -d instabox -c "SELECT * FROM events;"
psql -h $DB_HOST -U postgres -d instabox -c "SELECT photo_id, event_id, message FROM photos;"
```

La base **solo es alcanzable desde la instancia**: no tiene acceso público y su security group
únicamente admite el 5432 desde el grupo de la aplicación. Desde el equipo local no es posible
conectarse, y eso es deliberado.

Revisar los logs de la aplicación:

```bash
pm2 status
pm2 logs instabox --lines 30 --nostream
```

## 6. Eliminar todo

```bash
bash teardown.sh
```

Recursos que borra: instancia EC2, instancia RDS, DB subnet group, los dos security groups, el key
pair, el secret y el bucket con todo su contenido. También borra el `instabox.env` local, que ya
no apunta a nada.

---

## Desarrollo local

El código puede correr en el equipo local, pero necesita igualmente el secret y el bucket en AWS,
porque las credenciales de la base salen de Secrets Manager:

```bash
npm install
cp .env.example .env    # ajustar región, bucket y nombre del secret
npm run dev
```

Como el equipo local no tiene instance profile, el SDK usa las credenciales de
`~/.aws/credentials`. Conectarse a la base requeriría además hacerla accesible desde fuera, cosa
que `setup.sh` no hace a propósito.

## Estructura

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

preflight.sh                   revisión previa
setup.sh                       crea la infraestructura en AWS
deploy.sh                      sube el código a la EC2 y lo arranca
teardown.sh                    borra todos los recursos
```

## Problemas comunes

| Síntoma                                                         | Qué pasa                                            | Solución                                                        |
| --------------------------------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------- |
| `ExpiredToken` o `InvalidClientTokenId`                         | Caducaron las credenciales del lab                  | Volver a pegarlas en `~/.aws/credentials`                       |
| `Connection closed by ... port 22`                              | La instancia sigue arrancando                       | Esperar un minuto; `deploy.sh` reintenta solo                   |
| `UNPROTECTED PRIVATE KEY FILE`                                  | La `.pem` está en `/mnt/c`, donde `chmod` no aplica | Moverla al home de Linux y `chmod 400`                          |
| Postman: _no response_                                          | La instancia se reinició y cambió de IP             | Ejecutar `setup.sh` de nuevo y actualizar `base_url`            |
| Polaroid sin texto                                              | Faltan las fuentes en la instancia                  | `sudo apt install -y fonts-dejavu-core`                         |
| `Fontconfig error: Cannot load default config file` en los logs | Aviso de `sharp` al arrancar                        | Inofensivo si las polaroids salen con su mensaje                |
| `DependencyViolation` al borrar un SG                           | Otro grupo lo referencia                            | Borrar primero el de la base; el script ya lo hace en ese orden |
| La aplicación muere al cerrar el SSH                            | Se arrancó con `npm start` en vez de pm2            | `pm2 start dist/index.js --name instabox`                       |
| `psql` se queda colgado desde el equipo                         | La base no es pública, a propósito                  | Conectarse desde la instancia                                   |
| `$'\r': command not found` al correr un script                  | El archivo quedó con finales de línea CRLF          | `sed -i 's/\r$//' *.sh`                                         |

Una advertencia del Learner Lab: cuando la sesión termina, **la instancia EC2 se detiene y al
reiniciarla cambia su IP pública**.
