# Whisper SageMaker Serverless

Transcrição de áudios OGG (WhatsApp) com OpenAI Whisper em SageMaker Serverless Inference.

## Como funciona

```
Áudio .ogg (bytes) → SageMaker Serverless Endpoint → Whisper → Texto pt-BR
```

- Entrada: arquivo `.ogg` enviado diretamente no body da requisição
- Saída: JSON `{ "text": "transcrição aqui" }`
- Cold start: ~1–3 min na primeira chamada (endpoint hiberna quando ocioso)
- Custo: paga por invocação, zero custo quando não usado

## Estrutura

```
whisper-sagemaker/
├── model/
│   └── code/
│       └── inference.py        # converte OGG→WAV e chama o Whisper
├── deploy/
│   ├── create_role.sh          # cria a role IAM com policies inline
│   ├── deploy.sh               # deploy completo via AWS CLI
│   ├── cleanup.sh              # remove todos os recursos criados
│   ├── deploy.py               # deploy alternativo via SDK Python
│   └── test_endpoint.py        # testa o endpoint com um arquivo .ogg
├── scripts/
│   └── package_model.sh        # empacota model.tar.gz para o S3
└── requirements.txt
```

## Pré-requisitos

- AWS CLI configurado (`aws configure`)
- Usuário IAM com permissão para criar roles, buckets S3 e recursos SageMaker

Para testes locais:
- Python 3.10+
- ffmpeg instalado

```bash
pip install -r requirements.txt
```

## Deploy via AWS CLI

### 1. Empacotar o código de inferência

```bash
bash scripts/package_model.sh
```

Gera o `model.tar.gz` com o `inference.py` customizado. O modelo `openai/whisper-small`
é baixado automaticamente do Hugging Face Hub pela AWS — não é necessário empacotar os pesos.

### 2. Criar a role IAM

```bash
bash deploy/create_role.sh \
  --bucket meu-bucket-s3 \
  --region us-east-1 \
  --profile meu-profile
```

Cria a role `SageMakerWhisperRole` com policies inline restritas:
- Acesso de leitura/escrita apenas ao bucket informado
- Permissões mínimas de SageMaker, ECR e CloudWatch Logs

Se a role já existir, o script apenas atualiza as policies. Ao final, imprime
o ARN e o comando de deploy pronto para copiar.

### 3. Fazer o deploy

```bash
bash deploy/deploy.sh \
  --bucket meu-bucket-s3 \
  --role-arn arn:aws:iam::123456789012:role/SageMakerWhisperRole \
  --region us-east-1 \
  --profile meu-profile \
  --endpoint-name whisper-serverless
```

O script executa os seguintes passos:
1. Cria o bucket S3 caso não exista
2. Faz upload do `model.tar.gz`
3. Cria o SageMaker Model com a imagem HuggingFace DLC
4. Cria o Endpoint Config serverless
5. Cria ou atualiza o Endpoint
6. Aguarda o endpoint ficar `InService`

### 4. Testar

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name whisper-serverless \
  --content-type "audio/ogg" \
  --accept "application/json" \
  --body fileb://audio.ogg \
  --region us-east-1 \
  response.json && cat response.json
```

### Limpeza

Remove o endpoint, endpoint config e model criados:

```bash
bash deploy/cleanup.sh \
  --endpoint-name whisper-serverless \
  --region us-east-1 \
  --profile meu-profile
```

---

## Deploy alternativo via SDK Python

```bash
python deploy/deploy.py \
  --bucket meu-bucket-s3 \
  --region us-east-1 \
  --endpoint-name whisper-serverless
```

Requer as dependências do `requirements.txt` instaladas. O SDK resolve
automaticamente a URI da imagem DLC com base nas versões configuradas.

---

## Invocar via boto3

```python
import boto3, json

client = boto3.client("sagemaker-runtime", region_name="us-east-1")

with open("audio.ogg", "rb") as f:
    audio_bytes = f.read()

response = client.invoke_endpoint(
    EndpointName="whisper-serverless",
    ContentType="audio/ogg",
    Accept="application/json",
    Body=audio_bytes,
)

result = json.loads(response["Body"].read())
print(result["text"])
```

---

## Configurações

| Parâmetro | Valor padrão | Descrição |
|---|---|---|
| Modelo | `whisper-small` | Troque por `whisper-medium` para mais precisão |
| Memória | 3072 MB | Use 6144 MB para `whisper-medium` |
| Concorrência | 3 | Invocações simultâneas máximas |
| Max payload | 6 MB | Limite do SageMaker Serverless |

Parâmetros opcionais do `deploy.sh`:

| Flag | Padrão | Descrição |
|---|---|---|
| `--profile` | *(default)* | Profile do AWS CLI |
| `--region` | `us-east-1` | Região AWS |
| `--endpoint-name` | `whisper-serverless` | Nome do endpoint |
| `--memory` | `3072` | Memória do container em MB |
| `--concurrency` | `3` | Invocações simultâneas máximas |

---

## Estimativa de custo (us-east-1)

| Item | Valor |
|---|---|
| Por GB-segundo de processamento | $0.00006 |
| Por requisição | $0.0000200 |
| 1000 áudios de 30s, 3GB | ~$2–4/mês |
| Zero uso | $0 |
