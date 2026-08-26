# whisper-sagemaker — GitOps

Infraestrutura como código para provisionar o **Whisper SageMaker Serverless Endpoint** via Crossplane e ArgoCD.

## Estrutura

```
gitops/
├── apps/
│   └── whisper-sagemaker.yaml          # ArgoCD Application
└── charts/
    └── whisper-sagemaker/
        ├── Chart.yaml
        ├── values.yaml                  # parâmetros configuráveis
        └── templates/
            ├── providerconfig.yaml      # Crossplane ProviderConfig (IRSA)
            ├── iam-role.yaml            # IAM Role para o SageMaker
            ├── iam-policy-s3.yaml       # Policy inline: acesso ao bucket
            ├── iam-policy-sagemaker.yaml # Policy inline: SageMaker + ECR + CW
            ├── s3-bucket.yaml           # Bucket + bloqueio público
            ├── sagemaker-model.yaml     # SageMaker Model (HuggingFace DLC)
            ├── sagemaker-endpointconfig.yaml # EndpointConfig serverless
            └── sagemaker-endpoint.yaml  # Endpoint
```

## Pré-requisitos no cluster

### 1. Crossplane instalado

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace
```

### 2. Providers Upbound modulares instalados

```bash
# IAM
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-iam
spec:
  package: xpkg.upbound.io/upbound/provider-aws-iam:v1
EOF

# S3
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-s3
spec:
  package: xpkg.upbound.io/upbound/provider-aws-s3:v1
EOF

# SageMaker
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-sagemaker
spec:
  package: xpkg.upbound.io/upbound/provider-aws-sagemaker:v1
EOF
```

### 3. IRSA configurado para os providers

Cada provider precisa que sua `ServiceAccount` tenha a anotação com a role que o Crossplane vai assumir:

```bash
kubectl annotate serviceaccount \
  -n crossplane-system \
  provider-aws-iam \
  eks.amazonaws.com/role-arn=arn:aws:iam::ACCOUNT_ID:role/CrossplaneProviderRole

# Repita para provider-aws-s3 e provider-aws-sagemaker
```

A `CrossplaneProviderRole` precisa ter permissões de IAM, S3 e SageMaker no trust policy para `pods.eks.amazonaws.com`.

## Deploy via ArgoCD

### 1. Edite os valores no ArgoCD Application

Abra `apps/whisper-sagemaker.yaml` e ajuste:

| Campo | Descrição |
|---|---|
| `repoURL` | URL do seu repositório GitOps |
| `aws.accountId` | ID da conta AWS |
| `providerConfig.irsaRoleArn` | ARN da role do Crossplane |
| `s3.bucketName` | Nome único do bucket S3 |
| `sagemaker.endpointName` | Nome do endpoint |

### 2. Aplique a Application no cluster

```bash
kubectl apply -f apps/whisper-sagemaker.yaml
```

O ArgoCD vai sincronizar o chart e criar todos os recursos na ordem correta via `sync-wave`.

### 3. Acompanhe a criação

```bash
# Via ArgoCD CLI
argocd app get whisper-sagemaker
argocd app sync whisper-sagemaker

# Via kubectl — recursos Crossplane
kubectl get managed -n whisper-sagemaker
```

## Ordem de provisionamento (sync-waves)

| Wave | Recurso |
|---|---|
| -10 | ProviderConfig |
| -5 | IAM Role |
| -4 | IAM Policies (S3 + SageMaker) |
| -3 | S3 Bucket |
| -2 | BucketPublicAccessBlock / BucketVersioning |
| 0 | SageMaker Model |
| 1 | SageMaker EndpointConfig |
| 2 | SageMaker Endpoint |

## Valores configuráveis

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `aws.region` | `us-east-1` | Região AWS |
| `aws.accountId` | — | ID da conta AWS |
| `providerConfig.name` | `aws-provider-config` | Nome do ProviderConfig |
| `providerConfig.irsaRoleArn` | — | ARN da role IRSA do Crossplane |
| `iam.roleName` | `SageMakerWhisperRole` | Nome da role IAM do SageMaker |
| `s3.bucketName` | `whisper-sagemaker-models` | Nome do bucket S3 |
| `s3.versioning` | `false` | Habilita versionamento no bucket |
| `sagemaker.endpointName` | `whisper-serverless` | Nome do endpoint |
| `sagemaker.model.imageUri` | HF DLC v1.4 | Imagem Docker do container |
| `sagemaker.endpointConfig.memorySizeInMb` | `3072` | Memória do container (MB) |
| `sagemaker.endpointConfig.maxConcurrency` | `3` | Invocações simultâneas máximas |

> Para `whisper-medium`, use `memorySizeInMb: 6144` e atualize `HF_MODEL_ID`.
