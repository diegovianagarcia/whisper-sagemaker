"""
test_endpoint.py — Testa o endpoint Whisper enviando um arquivo OGG diretamente no body.

Uso:
  python deploy/test_endpoint.py --endpoint whisper-serverless --audio audio.ogg --region us-east-1
"""

import argparse
import json
import boto3


def get_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True, help="Nome do endpoint SageMaker")
    parser.add_argument("--audio",    required=True, help="Caminho para o arquivo .ogg")
    parser.add_argument("--region",   default="us-east-1", help="Região AWS")
    return parser.parse_args()


def main():
    args = get_args()

    # Lê o arquivo de áudio como bytes brutos
    with open(args.audio, "rb") as f:
        audio_bytes = f.read()

    file_size_kb = len(audio_bytes) / 1024
    print(f"✔ Arquivo : {args.audio} ({file_size_kb:.1f} KB)")
    print(f"✔ Endpoint: {args.endpoint}")
    print(f"✔ Região  : {args.region}")
    print("\n⏳ Invocando endpoint (primeira chamada pode ter cold start de 1-3 min)...")

    # Invoca o endpoint enviando os bytes diretamente
    client = boto3.client("sagemaker-runtime", region_name=args.region)
    response = client.invoke_endpoint(
        EndpointName=args.endpoint,
        ContentType="audio/ogg",        # bytes brutos OGG/Opus
        Accept="application/json",
        Body=audio_bytes,
    )

    # Lê e exibe o resultado
    result = json.loads(response["Body"].read().decode("utf-8"))

    print("\n✅ Transcrição:")
    print(f'   {result["text"]}')


if __name__ == "__main__":
    main()
