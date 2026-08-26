#!/usr/bin/env bash
# deploy/deploy.sh
#
# Deploy do Whisper como SageMaker Serverless Endpoint usando AWS CLI puro.
#
# Pré-requisitos:
#   - AWS CLI configurado (aws configure)
#   - Role IAM com permissões mínimas (use create_role.sh para criar)
#   - model.tar.gz gerado por: bash scripts/package_model.sh
#
# Uso:
#   bash deploy/deploy.sh \
#     --bucket meu-bucket-s3 \
#     --role-arn arn:aws:iam::123456789012:role/SageMakerRole \
#     [--profile meu-profile] \
#     [--region us-east-1] \
#     [--endpoint-name whisper-serverless] \
#     [--memory 3072] \
#     [--concurrency 3]

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
REGION="us-east-1"
ENDPOINT_NAME="whisper-serverless"
MEMORY_MB=3072
CONCURRENCY=3
BUCKET=""
ROLE_ARN=""
PROFILE=""

# ─── Parse de argumentos ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)        BUCKET="$2";        shift 2 ;;
    --role-arn)      ROLE_ARN="$2";      shift 2 ;;
    --profile)       PROFILE="$2";       shift 2 ;;
    --region)        REGION="$2";        shift 2 ;;
    --endpoint-name) ENDPOINT_NAME="$2"; shift 2 ;;
    --memory)        MEMORY_MB="$2";     shift 2 ;;
    --concurrency)   CONCURRENCY="$2";   shift 2 ;;
    *)
      echo "❌ Argumento desconhecido: $1"
      echo "Uso: bash deploy/deploy.sh --bucket <bucket> --role-arn <arn> [--profile <profile>] [opções]"
      exit 1
      ;;
  esac
done

# ─── Validação ────────────────────────────────────────────────────────────────
if [[ -z "$BUCKET" ]]; then
  echo "❌ --bucket é obrigatório"
  exit 1
fi

if [[ -z "$ROLE_ARN" ]]; then
  echo "❌ --role-arn é obrigatório"
  echo "   Dica: bash deploy/create_role.sh --bucket $BUCKET"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MODEL_TAR="$PROJECT_DIR/model.tar.gz"

if [[ ! -f "$MODEL_TAR" ]]; then
  echo "❌ model.tar.gz não encontrado. Execute primeiro:"
  echo "   bash scripts/package_model.sh"
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

# ─── Nomes dos recursos ───────────────────────────────────────────────────────
MODEL_NAME="$ENDPOINT_NAME-model"
CONFIG_NAME="$ENDPOINT_NAME-config"
S3_KEY="whisper-sagemaker/model/model.tar.gz"
S3_URI="s3://$BUCKET/$S3_KEY"

# Imagem HF DLC: transformers 4.37 + pytorch 2.1 + CPU + python 3.10
# Conta 763104351884 = conta pública da AWS para imagens DLC
IMAGE_URI="763104351884.dkr.ecr.${REGION}.amazonaws.com/huggingface-pytorch-inference:2.1.0-transformers4.37.0-cpu-py310-ubuntu22.04-v1.4"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Whisper SageMaker Serverless — Deploy         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Região        : $REGION"
echo "  Bucket        : $BUCKET"
echo "  Role ARN      : $ROLE_ARN"
echo "  Endpoint      : $ENDPOINT_NAME"
echo "  Memória       : ${MEMORY_MB} MB"
echo "  Concorrência  : $CONCURRENCY"
echo "  Profile       : ${PROFILE:-default}"
echo "  Imagem DLC    : $IMAGE_URI"
echo ""

# ─── 1. Criar bucket S3 se não existir ───────────────────────────────────────
echo "⏳ [1/6] Verificando bucket S3..."

if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "✔  Bucket já existe: $BUCKET"
else
  echo "   Bucket não encontrado. Criando $BUCKET..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --output text > /dev/null
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" \
      --output text > /dev/null
  fi
  echo "✔  Bucket criado: $BUCKET"
fi
echo ""

# ─── 2. Upload do model.tar.gz ────────────────────────────────────────────────
echo "⏳ [2/6] Enviando model.tar.gz para o S3..."
aws s3 cp "$MODEL_TAR" "$S3_URI" --region "$REGION"
echo "✔  Arquivo enviado: $S3_URI"
echo ""

# ─── 3. Criar o Model ────────────────────────────────────────────────────────
echo "⏳ [3/6] Criando SageMaker Model..."

aws sagemaker delete-model \
  --model-name "$MODEL_NAME" \
  --region "$REGION" 2>/dev/null && echo "   ℹ️  Model anterior removido." || true

# Retry com backoff — a role IAM pode levar alguns segundos para propagar
MAX_ATTEMPTS=5
ATTEMPT=1
until aws sagemaker create-model \
  --model-name "$MODEL_NAME" \
  --primary-container "{
    \"Image\": \"$IMAGE_URI\",
    \"ModelDataUrl\": \"$S3_URI\",
    \"Environment\": {
      \"HF_MODEL_ID\": \"openai/whisper-small\",
      \"HF_TASK\": \"automatic-speech-recognition\"
    }
  }" \
  --execution-role-arn "$ROLE_ARN" \
  --region "$REGION" \
  --output text > /dev/null 2>&1; do
  if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
    echo "❌ Falha ao criar o model após $MAX_ATTEMPTS tentativas."
    echo "   Verifique se a role '$ROLE_ARN' existe e tem a trust policy correta."
    exit 1
  fi
  echo "   ⏱️  Aguardando propagação da role IAM... (tentativa $ATTEMPT/$MAX_ATTEMPTS)"
  sleep $((ATTEMPT * 10))
  ATTEMPT=$((ATTEMPT + 1))
done

echo "✔  Model criado: $MODEL_NAME"
echo ""

# ─── 4. Criar o Endpoint Config ──────────────────────────────────────────────
echo "⏳ [4/6] Criando Endpoint Config..."

aws sagemaker delete-endpoint-config \
  --endpoint-config-name "$CONFIG_NAME" \
  --region "$REGION" 2>/dev/null && echo "   ℹ️  Config anterior removida." || true

aws sagemaker create-endpoint-config \
  --endpoint-config-name "$CONFIG_NAME" \
  --production-variants "[{
    \"VariantName\": \"AllTraffic\",
    \"ModelName\": \"$MODEL_NAME\",
    \"ServerlessConfig\": {
      \"MemorySizeInMB\": $MEMORY_MB,
      \"MaxConcurrency\": $CONCURRENCY
    }
  }]" \
  --region "$REGION" \
  --output text > /dev/null

echo "✔  Endpoint config criada: $CONFIG_NAME"
echo ""

# ─── 5. Criar o Endpoint ─────────────────────────────────────────────────────
echo "⏳ [5/6] Criando Endpoint..."

EXISTING_STATUS=$(aws sagemaker describe-endpoint \
  --endpoint-name "$ENDPOINT_NAME" \
  --region "$REGION" \
  --query "EndpointStatus" \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$EXISTING_STATUS" == "NOT_FOUND" ]]; then
  aws sagemaker create-endpoint \
    --endpoint-name "$ENDPOINT_NAME" \
    --endpoint-config-name "$CONFIG_NAME" \
    --region "$REGION" \
    --output text > /dev/null
  echo "✔  Endpoint criado: $ENDPOINT_NAME"
elif [[ "$EXISTING_STATUS" == "Failed" ]]; then
  echo "   ℹ️  Endpoint em estado Failed. Deletando e recriando..."
  aws sagemaker delete-endpoint \
    --endpoint-name "$ENDPOINT_NAME" \
    --region "$REGION" > /dev/null
  # Aguarda a deleção completar
  echo "   ⏱️  Aguardando deleção do endpoint anterior..."
  aws sagemaker wait endpoint-deleted \
    --endpoint-name "$ENDPOINT_NAME" \
    --region "$REGION"
  aws sagemaker create-endpoint \
    --endpoint-name "$ENDPOINT_NAME" \
    --endpoint-config-name "$CONFIG_NAME" \
    --region "$REGION" \
    --output text > /dev/null
  echo "✔  Endpoint recriado: $ENDPOINT_NAME"
else
  echo "   ℹ️  Endpoint já existe (status: $EXISTING_STATUS). Atualizando..."
  aws sagemaker update-endpoint \
    --endpoint-name "$ENDPOINT_NAME" \
    --endpoint-config-name "$CONFIG_NAME" \
    --region "$REGION" \
    --output text > /dev/null
  echo "✔  Endpoint atualizado: $ENDPOINT_NAME"
fi
echo ""

# ─── 6. Aguardar o endpoint ficar InService ──────────────────────────────────
echo "⏳ [6/6] Aguardando endpoint ficar InService (pode levar alguns minutos)..."
aws sagemaker wait endpoint-in-service \
  --endpoint-name "$ENDPOINT_NAME" \
  --region "$REGION"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              ✅ Deploy concluído!                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Endpoint : $ENDPOINT_NAME"
echo "  Região   : $REGION"
echo ""
echo "Para testar:"
echo "  aws sagemaker-runtime invoke-endpoint \\"
echo "    --endpoint-name \"$ENDPOINT_NAME\" \\"
echo "    --content-type \"audio/ogg\" \\"
echo "    --accept \"application/json\" \\"
echo "    --body fileb://audio.ogg \\"
echo "    --region \"$REGION\" \\"
[[ -n "$PROFILE" ]] && echo "    --profile \"$PROFILE\" \\"
echo "    response.json && cat response.json"
echo ""
echo "Para deletar tudo:"
CLEANUP_CMD="  bash deploy/cleanup.sh --endpoint-name \"$ENDPOINT_NAME\" --region \"$REGION\""
[[ -n "$PROFILE" ]] && CLEANUP_CMD="$CLEANUP_CMD --profile \"$PROFILE\""
echo "$CLEANUP_CMD"
echo ""
