import io
import os
import json
import tempfile
import subprocess
import numpy as np
import soundfile as sf
from transformers import pipeline

# Carregado uma vez quando o container inicia
MODEL_ID = os.environ.get("HF_MODEL_ID", "openai/whisper-small")
_pipe = None


def model_fn(model_dir):
    """Inicializa o pipeline do Whisper. Chamado uma vez pelo SageMaker."""
    global _pipe
    _pipe = pipeline(
        "automatic-speech-recognition",
        model=MODEL_ID,
        chunk_length_s=30,          # processa em chunks de 30s para áudios longos
        stride_length_s=5,          # overlap entre chunks
        return_timestamps=False,
    )
    return _pipe


def input_fn(request_body, request_content_type):
    """
    Recebe os bytes brutos do áudio OGG diretamente no body.
    Content-Type esperado: audio/ogg
    """
    supported = ("audio/ogg", "audio/mpeg", "audio/wav", "audio/flac", "application/octet-stream")
    if request_content_type not in supported:
        raise ValueError(f"Content-Type '{request_content_type}' não suportado. Use: {supported}")

    return request_body  # bytes brutos


def _convert_to_wav(audio_bytes: bytes) -> np.ndarray:
    """
    Converte qualquer formato de áudio (OGG/Opus, MP3, etc.) para
    array numpy de float32 a 16kHz mono — formato esperado pelo Whisper.
    Usa ffmpeg que já está disponível no Hugging Face DLC da AWS.
    """
    with tempfile.NamedTemporaryFile(suffix=".input", delete=False) as f_in:
        f_in.write(audio_bytes)
        input_path = f_in.name

    output_path = input_path + ".wav"

    try:
        subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", input_path,
                "-ar", "16000",   # 16kHz
                "-ac", "1",       # mono
                "-f", "wav",
                output_path,
            ],
            check=True,
            capture_output=True,
        )
        audio_array, sample_rate = sf.read(output_path, dtype="float32")
    finally:
        os.unlink(input_path)
        if os.path.exists(output_path):
            os.unlink(output_path)

    return audio_array


def predict_fn(audio_bytes, pipe):
    """Converte o áudio e executa a transcrição com Whisper."""
    audio_array = _convert_to_wav(audio_bytes)

    result = pipe(
        {"array": audio_array, "sampling_rate": 16000},
        generate_kwargs={"task": "transcribe"},  # mantém idioma original (pt-BR → pt-BR)
    )

    return result


def output_fn(prediction, accept):
    """Formata a resposta como JSON."""
    response = {
        "text": prediction["text"].strip(),
    }
    return json.dumps(response, ensure_ascii=False), "application/json"
