#!/usr/bin/env bash
# deploy/create_role.sh
#
# Cria a role IAM necessária para o deploy do Whisper no SageMaker.
# Usa policies inline restritas ao bucket e às ações mínimas necessárias.
#
# Uso:
#   bash deploy/create_role.sh \
#     --bucket meu-bucket-s3 \
#     [--profile meu-profile] \
#     [--region us-east-1] \
#     [--role-name SageMakerWhisperRole]

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
REGION="us-east-1"
ROLE_NAME="SageMakerWhisperRole"
BUCKET=""
PROFILE=""

# ─── Parse de argumentos ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)    BUCKET="$2";    shift 2 ;;
    --profile)   PROFILE="$2";   shift 2 ;;
    --region)    REGION="$2";    shift 2 ;;
    --role-name) ROLE_NAME="$2"; shift 2 ;;
    *)
      echo "❌ Argumento desconhecido: $1"
      echo "Uso: bash deploy/create_role.sh --bucket <bucket> [--profile <profile>] [--region us-east-1] [--role-name SageMakerWhisperRole]"
      exit 1
      ;;
  esac
done

if [[ -z "$BUCKET" ]]; then
  echo "❌ --bucket é obrigatório"
  exit 1
fi

# ─── Função wrapper para o AWS CLI (injeta --profile se informado) ────────────
aws() {
  if [[ -n "$PROFILE" ]]; then
    command aws --profile "$PROFILE" "$@"
  else
    command aws "$@"
  fi
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         Criando Role IAM para o Whisper              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Role    : $ROLE_NAME"
echo "  Bucket  : $BUCKET"
echo "  Região  : $REGION"
echo "  Profile : ${PROFILE:-default}"
echo ""

# ─── Verificar se a role já existe ────────────────────────────────────────────
EXISTING_ARN=$(aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query "Role.Arn" \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$EXISTING_ARN" != "NOT_FOUND" ]]; then
  echo "ℹ️  Role já existe: $EXISTING_ARN"
  echo "   Atualizando as policies inline..."
  echo ""
else
  # ─── 1. Criar a role com trust policy ─────────────────────────────────────
  echo "⏳ [1/3] Criando role IAM..."

  TRUST_POLICY=$(cat << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "sagemaker.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

  EXISTING_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Role para o Whisper SageMaker Serverless Endpoint" \
    --query "Role.Arn" \
    --output text)

  echo "✔  Role criada: $EXISTING_ARN"
  echo "   ⏱️  Aguardando propagação do IAM (15s)..."
  sleep 15
  echo ""
fi

# ─── 2. Policy inline: acesso restrito ao bucket S3 ──────────────────────────
echo "⏳ [2/3] Aplicando policy de acesso ao S3 (bucket: $BUCKET)..."

S3_POLICY=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3WhisperBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/*"
      ]
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "S3WhisperBucketAccess" \
  --policy-document "$S3_POLICY"

echo "✔  Policy S3WhisperBucketAccess aplicada"
echo ""

# ─── 3. Policy inline: SageMaker + ECR + CloudWatch ──────────────────────────
echo "⏳ [3/3] Aplicando policy do SageMaker, ECR e CloudWatch..."

SAGEMAKER_POLICY=$(cat << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SageMakerInference",
      "Effect": "Allow",
      "Action": [
        "sagemaker:CreateModel",
        "sagemaker:CreateEndpointConfig",
        "sagemaker:CreateEndpoint",
        "sagemaker:UpdateEndpoint",
        "sagemaker:DeleteEndpoint",
        "sagemaker:DeleteEndpointConfig",
        "sagemaker:DeleteModel",
        "sagemaker:DescribeEndpoint",
        "sagemaker:InvokeEndpoint"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRPullImage",
      "Effect": "Allow",
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/sagemaker/*"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "SageMakerWhisperInference" \
  --policy-document "$SAGEMAKER_POLICY"

echo "✔  Policy SageMakerWhisperInference aplicada"
echo ""

# ─── Resultado final ──────────────────────────────────────────────────────────
ROLE_ARN=$(aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query "Role.Arn" \
  --output text)

echo "╔══════════════════════════════════════════════════════╗"
echo "║                  ✅ Role pronta!                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  ARN: $ROLE_ARN"
echo ""
echo "Próximo passo — fazer o deploy:"
echo ""
DEPLOY_CMD="  bash deploy/deploy.sh \\\n    --bucket \"$BUCKET\" \\\n    --role-arn \"$ROLE_ARN\" \\\n    --region \"$REGION\""
[[ -n "$PROFILE" ]] && DEPLOY_CMD="$DEPLOY_CMD \\\n    --profile \"$PROFILE\""
echo -e "$DEPLOY_CMD"
echo ""
