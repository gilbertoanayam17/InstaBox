#!/usr/bin/env bash
# Elimina todos los recursos de AWS que usa InstaBox.
# Uso:  bash teardown.sh
# No usa "set -e" a propósito: si un recurso ya no existe, el script sigue con los demás.

REGION=${REGION:-us-east-1}
PREFIX=instabox

DB_ID=$PREFIX-db
SECRET_ID=$PREFIX/rds
KEY_NAME=$PREFIX-key
SG_APP_NAME=$PREFIX-app-sg
SG_DB_NAME=$PREFIX-db-sg
SUBNET_GROUP=$PREFIX-subnets
TAG_NAME=$PREFIX-server

echo "=============================================="
echo " Eliminando recursos de InstaBox en $REGION"
echo "=============================================="

# ---------------------------------------------------------------- EC2
echo ""
echo "--> Instancia EC2"
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$TAG_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION")

if [ -n "$INSTANCE_IDS" ]; then
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" --output text > /dev/null
    echo "    terminando: $INSTANCE_IDS"
else
    echo "    no hay instancias que eliminar"
fi

# ---------------------------------------------------------------- RDS
echo ""
echo "--> Instancia RDS"
if aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$REGION" > /dev/null 2>&1; then
    aws rds delete-db-instance \
        --db-instance-identifier "$DB_ID" \
        --skip-final-snapshot \
        --delete-automated-backups \
        --region "$REGION" --output text > /dev/null
    echo "    eliminando: $DB_ID"
else
    echo "    no existe $DB_ID"
fi

# Las dos esperas van juntas porque ambos recursos tardan varios minutos.
if [ -n "$INSTANCE_IDS" ]; then
    echo ""
    echo "    esperando a que la EC2 termine..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
    echo "    EC2 eliminada"
fi

if aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$REGION" > /dev/null 2>&1; then
    echo "    esperando a que RDS termine (puede tardar varios minutos)..."
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" --region "$REGION"
    echo "    RDS eliminada"
fi

# ---------------------------------------------------------------- Subnet group
echo ""
echo "--> DB subnet group"
aws rds delete-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" --region "$REGION" 2>/dev/null \
    && echo "    eliminado: $SUBNET_GROUP" \
    || echo "    no existe $SUBNET_GROUP"

# ---------------------------------------------------------------- Security Groups
# Van hasta aquí porque no se pueden borrar mientras la EC2 o la RDS los usen.
echo ""
echo "--> Security Groups"
for SG in "$SG_APP_NAME" "$SG_DB_NAME"; do
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG" \
        --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null)

    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" \
            && echo "    eliminado: $SG ($SG_ID)" \
            || echo "    no se pudo eliminar $SG, revisa que nada lo esté usando"
    else
        echo "    no existe $SG"
    fi
done

# ---------------------------------------------------------------- Key Pair
echo ""
echo "--> Key Pair"
aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" 2>/dev/null \
    && echo "    eliminado: $KEY_NAME" \
    || echo "    no existe $KEY_NAME"

# ---------------------------------------------------------------- Secret
# force-delete-without-recovery: sin esto el nombre queda apartado hasta 30 días
# y no podrías volver a crear el secret con el mismo nombre.
echo ""
echo "--> Secret de Secrets Manager"
aws secretsmanager delete-secret \
    --secret-id "$SECRET_ID" \
    --force-delete-without-recovery \
    --region "$REGION" --output text > /dev/null 2>&1 \
    && echo "    eliminado: $SECRET_ID" \
    || echo "    no existe $SECRET_ID"

# ---------------------------------------------------------------- S3
# Un bucket solo se puede borrar si está vacío.
echo ""
echo "--> Bucket de S3"
BUCKETS=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '$PREFIX-fotos')].Name" --output text)

if [ -n "$BUCKETS" ]; then
    for B in $BUCKETS; do
        echo "    vaciando s3://$B"
        aws s3 rm "s3://$B" --recursive > /dev/null
        aws s3api delete-bucket --bucket "$B" --region "$REGION" \
            && echo "    eliminado: $B"
    done
else
    echo "    no hay buckets con el prefijo $PREFIX-fotos"
fi

# ---------------------------------------------------------------- Comprobación
echo ""
echo "=============================================="
echo " Comprobación final"
echo "=============================================="

echo ""
echo "Instancias EC2 de InstaBox:"
aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$TAG_NAME" \
    --query "Reservations[].Instances[].{ID:InstanceId,Estado:State.Name}" \
    --output table --region "$REGION"

echo "Instancias RDS:"
aws rds describe-db-instances \
    --query "DBInstances[].{ID:DBInstanceIdentifier,Estado:DBInstanceStatus}" \
    --output table --region "$REGION"

echo "Buckets de S3:"
aws s3 ls | grep "$PREFIX" || echo "    ninguno"

echo "Secrets:"
aws secretsmanager list-secrets \
    --query "SecretList[?starts_with(Name, '$PREFIX')].Name" \
    --output table --region "$REGION"

echo ""
echo "Listo. Si alguna tabla salió vacía, ese recurso ya no existe."
