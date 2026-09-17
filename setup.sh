#!/usr/bin/env bash
# Crea toda la infraestructura de InstaBox en AWS:
# bucket de S3, security groups, subnet group, instancia RDS, secret y instancia EC2.
#
# Uso:  bash setup.sh
#
# Se puede volver a correr: los recursos que ya existen se reutilizan.
# Al terminar deja los datos en instabox.env, que usan deploy.sh y teardown.sh.

set -uo pipefail

REGION=${REGION:-us-east-1}
PREFIX=instabox
AMI=${AMI:-ami-0f8a61b66d1accaee}          # Ubuntu Server 24.04 LTS (us-east-1)
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.small}   # micro se queda corta al compilar
DB_CLASS=${DB_CLASS:-db.t3.micro}

DB_ID=$PREFIX-db
DB_NAME=instabox
DB_USER=postgres
SECRET_ID=$PREFIX/rds
KEY_NAME=$PREFIX-key
SG_APP_NAME=$PREFIX-app-sg
SG_DB_NAME=$PREFIX-db-sg
SUBNET_GROUP=$PREFIX-subnets
TAG_NAME=$PREFIX-server

# La llave privada va al home de Linux: en /mnt/c (WSL) el chmod no surte efecto
# y ssh rechaza la llave por permisos demasiado abiertos.
KEY_PATH=$HOME/$KEY_NAME.pem
ENV_FILE=$(dirname "$0")/instabox.env

morir() { echo ""; echo "ERROR: $1"; exit 1; }

echo "=============================================="
echo " InstaBox: creando infraestructura en $REGION"
echo "=============================================="

# ---------------------------------------------------------------- cuenta
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
    || morir "no hay credenciales válidas. Corre primero: bash preflight.sh"

BUCKET=$PREFIX-fotos-$ACCOUNT_ID
echo ""
echo "Cuenta:  $ACCOUNT_ID"
echo "Bucket:  $BUCKET"

# ---------------------------------------------------------------- S3
# El nombre lleva el número de cuenta porque los buckets son únicos en todo el mundo.
echo ""
echo "--> Bucket de S3"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" > /dev/null 2>&1; then
    echo "    ya existe: $BUCKET"
else
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" > /dev/null \
            || morir "no se pudo crear el bucket"
    else
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION" > /dev/null \
            || morir "no se pudo crear el bucket"
    fi
    echo "    creado: $BUCKET"
fi

# ---------------------------------------------------------------- VPC
VPC_ID=$(aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text --region "$REGION")
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || morir "no se encontró ninguna VPC en $REGION"
echo ""
echo "--> Red"
echo "    VPC: $VPC_ID"

# ---------------------------------------------------------------- Security Group de la app
echo ""
echo "--> Security Group de la app"
SG_APP=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_APP_NAME" \
    --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null)

if [ -z "$SG_APP" ] || [ "$SG_APP" = "None" ]; then
    SG_APP=$(aws ec2 create-security-group \
        --group-name "$SG_APP_NAME" \
        --description "InstaBox: SSH y API" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" --output text --region "$REGION") \
        || morir "no se pudo crear el security group de la app"
    echo "    creado: $SG_APP"

    MI_IP=$(curl -s -m 10 https://checkip.amazonaws.com)
    if [ -n "$MI_IP" ]; then
        aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
            --protocol tcp --port 22 --cidr "$MI_IP/32" --region "$REGION" > /dev/null
        echo "    puerto 22 abierto solo para $MI_IP"
    else
        aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
            --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION" > /dev/null
        echo "    puerto 22 abierto a 0.0.0.0/0 (no se detectó tu IP pública)"
    fi

    # El 3000 va abierto para poder probar la API desde Postman.
    aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
        --protocol tcp --port 3000 --cidr 0.0.0.0/0 --region "$REGION" > /dev/null
    echo "    puerto 3000 abierto a internet"
else
    echo "    ya existe: $SG_APP"
fi

# ---------------------------------------------------------------- Security Group de la base
echo ""
echo "--> Security Group de la base de datos"
SG_DB=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_DB_NAME" \
    --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null)

if [ -z "$SG_DB" ] || [ "$SG_DB" = "None" ]; then
    SG_DB=$(aws ec2 create-security-group \
        --group-name "$SG_DB_NAME" \
        --description "InstaBox: Postgres solo desde la app" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" --output text --region "$REGION") \
        || morir "no se pudo crear el security group de la base"

    # El 5432 no se abre a una IP, sino AL OTRO SECURITY GROUP: solo lo que viva
    # en el grupo de la app puede hablarle a la base.
    aws ec2 authorize-security-group-ingress --group-id "$SG_DB" \
        --protocol tcp --port 5432 --source-group "$SG_APP" --region "$REGION" > /dev/null
    echo "    creado: $SG_DB (5432 solo desde $SG_APP_NAME)"
else
    echo "    ya existe: $SG_DB"
fi

# ---------------------------------------------------------------- subnet group
echo ""
echo "--> DB subnet group"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$SUBNET_GROUP" --region "$REGION" > /dev/null 2>&1; then
    echo "    ya existe: $SUBNET_GROUP"
else
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "Subnets[].SubnetId" --output text --region "$REGION")
    aws rds create-db-subnet-group \
        --db-subnet-group-name "$SUBNET_GROUP" \
        --db-subnet-group-description "Subnets para InstaBox" \
        --subnet-ids $SUBNETS --region "$REGION" > /dev/null \
        || morir "no se pudo crear el subnet group"
    echo "    creado: $SUBNET_GROUP"
fi

# ---------------------------------------------------------------- RDS
echo ""
echo "--> Instancia RDS PostgreSQL"
DB_EXISTE=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query "DBInstances[0].DBInstanceIdentifier" --output text --region "$REGION" 2>/dev/null)

if [ -n "$DB_EXISTE" ] && [ "$DB_EXISTE" != "None" ]; then
    echo "    ya existe: $DB_ID"
    if ! aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" > /dev/null 2>&1; then
        morir "la base existe pero el secret no. Como la contraseña solo se conoce al crearla,
       borra la base y vuelve a empezar:  bash teardown.sh"
    fi
    DB_PASS=""
else
    # RDS no acepta / @ \" ni espacios en la contraseña.
    DB_PASS=$(openssl rand -base64 18 | tr -d '/@" ')

    aws rds create-db-instance \
        --db-instance-identifier "$DB_ID" \
        --db-instance-class "$DB_CLASS" \
        --engine postgres \
        --master-username "$DB_USER" \
        --master-user-password "$DB_PASS" \
        --allocated-storage 20 \
        --db-name "$DB_NAME" \
        --vpc-security-group-ids "$SG_DB" \
        --db-subnet-group-name "$SUBNET_GROUP" \
        --no-publicly-accessible \
        --no-multi-az \
        --backup-retention-period 0 \
        --region "$REGION" > /dev/null \
        || morir "no se pudo crear la instancia RDS"
    echo "    creando: $DB_ID"
fi

echo "    esperando a que esté disponible (5 a 10 minutos)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_ID" --region "$REGION" \
    || morir "la instancia RDS no llegó a estar disponible"

DB_HOST=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query "DBInstances[0].Endpoint.Address" --output text --region "$REGION")
echo "    lista: $DB_HOST"

# ---------------------------------------------------------------- Secret
echo ""
echo "--> Secret en Secrets Manager"
SECRET_JSON="{\"username\":\"$DB_USER\",\"password\":\"$DB_PASS\",\"host\":\"$DB_HOST\",\"port\":5432,\"dbname\":\"$DB_NAME\"}"

if aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" > /dev/null 2>&1; then
    if [ -n "$DB_PASS" ]; then
        aws secretsmanager put-secret-value --secret-id "$SECRET_ID" \
            --secret-string "$SECRET_JSON" --region "$REGION" > /dev/null
        echo "    actualizado: $SECRET_ID"
    else
        echo "    ya existe: $SECRET_ID (se conserva la contraseña guardada)"
    fi
else
    aws secretsmanager create-secret \
        --name "$SECRET_ID" \
        --description "Credenciales de RDS para InstaBox" \
        --secret-string "$SECRET_JSON" \
        --region "$REGION" > /dev/null \
        || morir "no se pudo crear el secret"
    echo "    creado: $SECRET_ID"
fi

# ---------------------------------------------------------------- Key pair
echo ""
echo "--> Key pair"
KEY_EXISTE=$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" \
    --query "KeyPairs[0].KeyName" --output text --region "$REGION" 2>/dev/null)

if [ -n "$KEY_EXISTE" ] && [ "$KEY_EXISTE" != "None" ]; then
    if [ -f "$KEY_PATH" ]; then
        echo "    ya existe: $KEY_PATH"
    else
        morir "el key pair $KEY_NAME existe en AWS pero no tienes el archivo $KEY_PATH.
       La llave privada solo se puede descargar una vez. Bórralo y vuelve a correr setup.sh:
       aws ec2 delete-key-pair --key-name $KEY_NAME --region $REGION"
    fi
else
    aws ec2 create-key-pair --key-name "$KEY_NAME" \
        --query 'KeyMaterial' --output text --region "$REGION" > "$KEY_PATH" \
        || morir "no se pudo crear el key pair"
    chmod 400 "$KEY_PATH"
    echo "    creado: $KEY_PATH"
fi

# ---------------------------------------------------------------- EC2
echo ""
echo "--> Instancia EC2"
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$TAG_NAME" "Name=instance-state-name,Values=pending,running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION" 2>/dev/null)

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo "    ya existe: $INSTANCE_ID"
else
    # El instance profile es lo que permite leer el secret sin credenciales propias.
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_APP" \
        --iam-instance-profile Name=LabInstanceProfile \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
        --query "Instances[0].InstanceId" --output text --region "$REGION") \
        || morir "no se pudo lanzar la instancia EC2"
    echo "    lanzada: $INSTANCE_ID"
fi

echo "    esperando a que arranque..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

EC2_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region "$REGION")
echo "    corriendo en $EC2_IP"

# ---------------------------------------------------------------- estado
cat > "$ENV_FILE" <<EOF
# Generado por setup.sh. No lo subas a git.
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
BUCKET=$BUCKET
VPC_ID=$VPC_ID
SG_APP=$SG_APP
SG_DB=$SG_DB
DB_ID=$DB_ID
DB_HOST=$DB_HOST
SECRET_ID=$SECRET_ID
KEY_PATH=$KEY_PATH
INSTANCE_ID=$INSTANCE_ID
EC2_IP=$EC2_IP
EOF

echo ""
echo "=============================================="
echo " Infraestructura lista"
echo "=============================================="
echo ""
echo "  EC2      $INSTANCE_ID  ($EC2_IP)"
echo "  RDS      $DB_HOST"
echo "  Bucket   $BUCKET"
echo "  Secret   $SECRET_ID"
echo "  Llave    $KEY_PATH"
echo ""
echo "  Datos guardados en instabox.env"
echo ""
echo "  Siguiente paso:  bash deploy.sh"
echo ""
