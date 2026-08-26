#!/usr/bin/env bash
# scripts/package_model.sh
#
# Empacota o inference.py no formato esperado pelo SageMaker Hugging Face DLC.
#
# Estrutura final do model.tar.gz:
#   code/
#   └── inference.py
#
# O modelo (whisper-small) é baixado automaticamente do HF Hub pela AWS
# via variável de ambiente HF_MODEL_ID — não precisa empacotar os pesos.
#
# Uso:
#   bash scripts/package_model.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT="$PROJECT_DIR/model.tar.gz"

echo "📦 Empacotando model.tar.gz..."
echo "   Origem : $PROJECT_DIR/model/code/inference.py"
echo "   Destino: $OUTPUT"

# Cria o tar.gz a partir da pasta model/
# O SageMaker espera que o inference.py esteja em code/inference.py dentro do tar
cd "$PROJECT_DIR/model"
tar -czf "$OUTPUT" code/

echo ""
echo "✅ model.tar.gz criado com sucesso!"
echo ""

# Exibe o conteúdo do pacote para conferência
echo "📋 Conteúdo do pacote:"
tar -tzf "$OUTPUT"

echo ""
echo "Tamanho: $(du -sh "$OUTPUT" | cut -f1)"
echo ""
echo "Próximo passo:"
echo "  python deploy/deploy.py --bucket <seu-bucket> --region <sua-regiao>"
