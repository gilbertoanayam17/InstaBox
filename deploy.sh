#!/usr/bin/env bash
# Copia el código a la instancia EC2, instala lo que necesita y lo deja corriendo con pm2.
#
# Uso:  bash deploy.sh
#
# Se puede volver a correr cada vez que cambies el código: reemplaza los archivos,
# recompila y reinicia el proceso.

set -uo pipefail

PROJECT_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=$PROJECT_DIR/instabox.env
TAR_LOCAL=/tmp/instabox-deploy.tar.gz

morir() { echo ""; echo "ERROR: $1"; exit 1; }

[ -f "$ENV_FILE" ] || morir "no existe instabox.env. Corre primero: bash setup.sh"
# shellcheck disable=SC1090
source "$ENV_FILE"

echo "=============================================="
echo " InstaBox: desplegando en $EC2_IP"
echo "=============================================="

SSH_OPTS="-i $KEY_PATH -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ConnectTimeout=10"

# ---------------------------------------------------------------- esperar SSH
# sshd empieza a escuchar antes de que cloud-init instale tu llave: en esa ventana
# la conexión se acepta y se cierra de inmediato ("Connection closed by ...").
echo ""
echo "--> Esperando a que la instancia acepte SSH"
LISTA=0
for INTENTO in $(seq 1 30); do
    if ssh $SSH_OPTS -o BatchMode=yes "ubuntu@$EC2_IP" 'exit 0' > /dev/null 2>&1; then
        LISTA=1
        echo "    conectado (intento $INTENTO)"
        break
    fi
    sleep 10
done

[ "$LISTA" -eq 1 ] || morir "la instancia no acepta SSH. Revisa que el puerto 22 de tu
       security group permita tu IP actual (cambia si te mueves de red)."

# ---------------------------------------------------------------- empaquetar
# Sin node_modules: pesa cientos de megas y los binarios nativos de sharp son
# los de tu sistema operativo, no los de Linux. Se instalan allá.
echo ""
echo "--> Empaquetando el proyecto"
tar czf "$TAR_LOCAL" \
    --exclude=node_modules \
    --exclude=dist \
    --exclude=.git \
    --exclude=.env \
    --exclude=instabox.env \
    --exclude='*.pem' \
    --exclude='*.tar.gz' \
    -C "$PROJECT_DIR" . || morir "no se pudo empaquetar el proyecto"

echo "    $(du -h "$TAR_LOCAL" | cut -f1) listos para enviar"

echo ""
echo "--> Copiando a la instancia"
scp $SSH_OPTS "$TAR_LOCAL" "ubuntu@$EC2_IP:~/instabox.tar.gz" > /dev/null \
    || morir "falló el scp"
echo "    copiado"

# ---------------------------------------------------------------- instalar y arrancar
echo ""
echo "--> Instalando y arrancando (la primera vez tarda unos minutos)"
echo ""

ssh $SSH_OPTS "ubuntu@$EC2_IP" "bash -s" -- "$BUCKET" "$REGION" "$SECRET_ID" <<'REMOTO'
set -e
BUCKET=$1
REGION=$2
SECRET_ID=$3
export DEBIAN_FRONTEND=noninteractive

if ! command -v node > /dev/null 2>&1; then
    echo "    instalando Node.js 22..."
    sudo apt-get update -qq
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - > /dev/null 2>&1
    sudo apt-get install -y -qq nodejs > /dev/null
fi
echo "    node $(node -v)"

# fonts-dejavu-core es obligatorio: sin fuentes, sharp dibuja la polaroid SIN el mensaje.
echo "    instalando fuentes, cliente de Postgres y utilidades..."
sudo apt-get install -y -qq fonts-dejavu-core postgresql-client unzip > /dev/null 2>&1

# AWS CLI dentro de la instancia: sirve para leer el secret usando el rol de la EC2.
if ! command -v aws > /dev/null 2>&1; then
    echo "    instalando AWS CLI..."
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install --update > /dev/null
fi

rm -rf ~/instabox
mkdir -p ~/instabox
tar xzf ~/instabox.tar.gz -C ~/instabox
cd ~/instabox

# Solo configuración: usuario y contraseña de la base salen de Secrets Manager.
cat > .env <<ENVEOF
PORT=3000
AWS_REGION=$REGION
S3_BUCKET=$BUCKET
DB_SECRET_ID=$SECRET_ID
ENVEOF

echo "    npm install..."
npm install --no-audit --no-fund --silent
echo "    compilando TypeScript..."
npm run build > /dev/null

if ! command -v pm2 > /dev/null 2>&1; then
    echo "    instalando pm2..."
    sudo npm install -g pm2 --silent > /dev/null 2>&1
fi

# pm2 mantiene el proceso vivo aunque se cierre la sesión SSH.
pm2 delete instabox > /dev/null 2>&1 || true
pm2 start dist/index.js --name instabox > /dev/null
pm2 save > /dev/null 2>&1

sleep 4
echo ""
pm2 status
echo ""
echo "    últimas líneas del arranque:"
pm2 logs instabox --lines 6 --nostream 2>/dev/null | tail -8
REMOTO

RESULTADO=$?
rm -f "$TAR_LOCAL"
[ "$RESULTADO" -eq 0 ] || morir "falló la instalación dentro de la instancia"

# ---------------------------------------------------------------- comprobar
echo ""
echo "--> Comprobando la API desde tu máquina"
SALUD=""
for INTENTO in 1 2 3 4 5 6; do
    SALUD=$(curl -s -m 10 "http://$EC2_IP:3000/health" 2>/dev/null)
    [ "$SALUD" = "OK" ] && break
    sleep 5
done

echo ""
echo "=============================================="
if [ "$SALUD" = "OK" ]; then
    echo " InstaBox está corriendo"
    echo "=============================================="
    echo ""
    echo "  API        http://$EC2_IP:3000"
    echo "  SSH        ssh -i $KEY_PATH ubuntu@$EC2_IP"
    echo ""
    echo "  Prueba en Postman con base_url = http://$EC2_IP:3000"
    echo ""
else
    echo " La API no respondió"
    echo "=============================================="
    echo ""
    echo "  Revisa los logs:"
    echo "    ssh -i $KEY_PATH ubuntu@$EC2_IP 'pm2 logs instabox --lines 30 --nostream'"
    echo ""
    exit 1
fi
