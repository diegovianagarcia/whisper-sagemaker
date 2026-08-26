"""
deploy.py — Empacota e faz deploy do Whisper como SageMaker Serverless Endpoint.

Pré-requisitos:
  - AWS CLI configurado (aws configure)
  - Role IAM com permissões: AmazonSageMakerFullAccess + S3 read/write
  - model.tar.gz gerado pelo scripts/package_model.sh

Uso:
  python deploy/deploy.py --bucket meu-bucket --region us-east-1
"""

import argparse
import boto3
import sagemaker
from sagemaker.huggingface import HuggingFaceModel
from sagemaker.serverless import ServerlessInferenceConfig


# ─── Configurações do modelo ────────────────────────────────────────────────
HF_MODEL_ID       = "openai/whisper-small"   # troque por whisper-medium se quiser mais precisão
HF_TASK           = "automatic-speech-recognition"
TRANSFORMERS_VER  = "4.37"
PYTORCH_VER       = "2.1"
PY_VER            = "py310"

# ─── Configurações Serverless ────────────────────────────────────────────────
# whisper-small  → 3072 MB é suficiente
# whisper-medium → use 6144 MB
SERVERLESS_MEMORY_MB   = 3072
SERVERLESS_CONCURRENCY = 3   # invocações simultâneas máximas


def get_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bucket",   required=True, help="Nome do bucket S3 para armazenar o model.tar.gz")
    parser.add_argument("--region",   default="us-east-1", help="Região AWS (default: us-east-1)")
    parser.add_argument("--role-arn", default=None, help="ARN da role IAM (opcional, usa a role padrão do SageMaker se omitido)")
    parser.add_argument("--endpoint-name", default="whisper-serverless", help="Nome do endpoint")
    return parser.parse_args()


def main():
    args = get_args()

    session   = sagemaker.Session(boto_session=boto3.Session(region_name=args.region))
    role      = args.role_arn or sagemaker.get_execution_role(session)

    print(f"✔ Região  : {args.region}")
    print(f"✔ Bucket  : {args.bucket}")
    print(f"✔ Role    : {role}")
    print(f"✔ Modelo  : {HF_MODEL_ID}")
    print(f"✔ Memória : {SERVERLESS_MEMORY_MB} MB")

    # ── Faz upload do model.tar.gz para o S3 ────────────────────────────────
    model_data = session.upload_data(
        path="model.tar.gz",
        bucket=args.bucket,
        key_prefix="whisper-sagemaker/model",
    )
    print(f"✔ model.tar.gz enviado para: {model_data}")

    # ── Define o modelo HuggingFace ─────────────────────────────────────────
    huggingface_model = HuggingFaceModel(
        model_data=model_data,
        role=role,
        transformers_version=TRANSFORMERS_VER,
        pytorch_version=PYTORCH_VER,
        py_version=PY_VER,
        env={
            "HF_MODEL_ID": HF_MODEL_ID,
            "HF_TASK": HF_TASK,
        },
        sagemaker_session=session,
    )

    # ── Configuração Serverless ─────────────────────────────────────────────
    serverless_config = ServerlessInferenceConfig(
        memory_size_in_mb=SERVERLESS_MEMORY_MB,
        max_concurrency=SERVERLESS_CONCURRENCY,
    )

    # ── Deploy ──────────────────────────────────────────────────────────────
    print("\n⏳ Iniciando deploy do endpoint serverless (pode levar alguns minutos)...")
    predictor = huggingface_model.deploy(
        endpoint_name=args.endpoint_name,
        serverless_inference_config=serverless_config,
    )

    print(f"\n✅ Endpoint criado com sucesso!")
    print(f"   Nome     : {predictor.endpoint_name}")
    print(f"   Região   : {args.region}")
    print(f"\nPara testar:")
    print(f"   python deploy/test_endpoint.py --endpoint {predictor.endpoint_name} --audio caminho/audio.ogg --region {args.region}")


if __name__ == "__main__":
    main()
