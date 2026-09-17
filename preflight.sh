#!/usr/bin/env bash
# Revisa que tengas todo lo necesario ANTES de crear recursos en AWS.
# Uso:  bash preflight.sh

REGION=${REGION:-us-east-1}
FALLAS=0

echo "=============================================="
echo " InstaBox: revisión previa"
echo "=============================================="
echo ""

# ---------------------------------------------------------------- herramientas
echo "--> Herramientas necesarias"
for CMD in aws ssh scp curl openssl tar python3; do
    if command -v "$CMD" > /dev/null 2>&1; then
        echo "    ok      $CMD"
    else
        echo "    FALTA   $CMD"
        FALLAS=$((FALLAS + 1))
    fi
done

# ---------------------------------------------------------------- versión del CLI
echo ""
echo "--> Versión del AWS CLI"
if command -v aws > /dev/null 2>&1; then
    VERSION=$(aws --version 2>&1)
    echo "    $VERSION"
    case "$VERSION" in
        aws-cli/2.*) : ;;
        *) echo "    aviso: se recomienda AWS CLI v2" ;;
    esac
fi

# ---------------------------------------------------------------- credenciales
echo ""
echo "--> Credenciales de AWS"
IDENTIDAD=$(aws sts get-caller-identity --output json --region "$REGION" 2>&1)

if echo "$IDENTIDAD" | grep -q "Account"; then
    ACCOUNT_ID=$(echo "$IDENTIDAD" | python3 -c "import sys,json;print(json.load(sys.stdin)['Account'])")
    ARN=$(echo "$IDENTIDAD" | python3 -c "import sys,json;print(json.load(sys.stdin)['Arn'])")
    echo "    ok      cuenta $ACCOUNT_ID"
    echo "            $ARN"
else
    echo "    FALLA   las credenciales no sirven o ya caducaron"
    echo ""
    echo "    En el AWS Learner Lab: botón 'AWS Details' -> 'AWS CLI: Show'"
    echo "    y pega el bloque completo en ~/.aws/credentials"
    FALLAS=$((FALLAS + 1))
fi

# ---------------------------------------------------------------- región y VPC
echo ""
echo "--> Región y red"
echo "    región: $REGION"
VPC_ID=$(aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text --region "$REGION" 2>/dev/null)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    echo "    ok      VPC $VPC_ID"
else
    echo "    FALLA   no se encontró ninguna VPC en $REGION"
    FALLAS=$((FALLAS + 1))
fi

# ---------------------------------------------------------------- instance profile
echo ""
echo "--> Instance profile LabInstanceProfile"
if aws iam get-instance-profile --instance-profile-name LabInstanceProfile > /dev/null 2>&1; then
    echo "    ok      existe"
else
    echo "    aviso   no se pudo confirmar (normal si el lab restringe IAM)"
    echo "            setup.sh lo usará de todos modos"
fi

# ---------------------------------------------------------------- resultado
echo ""
echo "=============================================="
if [ "$FALLAS" -eq 0 ]; then
    echo " Todo listo. Siguiente paso: bash setup.sh"
else
    echo " $FALLAS problema(s) por resolver antes de continuar"
fi
echo "=============================================="

exit "$FALLAS"
