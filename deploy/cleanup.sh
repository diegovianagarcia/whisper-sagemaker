#!/usr/bin/env bash
# deploy/cleanup.sh
#
# Remove todos os recursos SageMaker criados pelo deploy.sh.
#
# Uso:
#   bash deploy/cleanup.sh \
#     [--endpoint-name whisper-serverless] \
#     [--profile meu-profile] \
#     [--region us-east-1]

set -euo pipefail

REGION="us-east-1"
ENDPOINT_NAME="whisper-serverless"
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint-name) ENDPOINT_NAME="$2"; shift 2 ;;
    --profile)       PROFILE="$2";       shift 2 ;;
    --region)        REGION="$2";        shift 2 ;;
    *)
      echo "❌ Argumento desconhecido: $1"
      echo "Uso: bash deploy/cleanup.sh [--endpoint-name whisper-serverless] [--profile <profile>] [--region us-east-1]"
      exit 1
      ;;
  esac
done

# ─── Função wrapper para o AWS CLI (injeta --profile se informado) ────────────
aws() {
  if [[ -n "$PROFILE" ]]; then
    command aws --profile "$PROFILE" "$@"
  else
    command aws "$@"
  fi
}

MODEL_NAME="$ENDPOINT_NAME-model"
CONFIG_NAME="$ENDPOINT_NAME-config"

echo ""
echo "🗑️  Removendo recursos do endpoint: $ENDPOINT_NAME"
echo "    Região  : $REGION"
echo "    Profile : ${PROFILE:-default}"
echo ""

aws sagemaker delete-endpoint \
  --endpoint-name "$ENDPOINT_NAME" \
  --region "$REGION" 2>/dev/null \
  && echo "✔  Endpoint deletado: $ENDPOINT_NAME" \
  || echo "   ℹ️  Endpoint não encontrado (já deletado?)"

aws sagemaker delete-endpoint-config \
  --endpoint-config-name "$CONFIG_NAME" \
  --region "$REGION" 2>/dev/null \
  && echo "✔  Config deletada: $CONFIG_NAME" \
  || echo "   ℹ️  Config não encontrada."

aws sagemaker delete-model \
  --model-name "$MODEL_NAME" \
  --region "$REGION" 2>/dev/null \
  && echo "✔  Model deletado: $MODEL_NAME" \
  || echo "   ℹ️  Model não encontrado."

echo ""
echo "✅ Limpeza concluída."
echo ""
echo "Lembre-se de remover o model.tar.gz do S3 se não precisar mais:"
echo "  aws s3 rm s3://<seu-bucket>/whisper-sagemaker/model/model.tar.gz"
echo ""
