# deploy.ps1 — ФИНАЛЬНЫЙ скрипт DLP-стенда (Windows 10/11)
# Разместите этот файл в любом удобном месте (например, на рабочем столе)
# Запуск: PowerShell от имени Администратора

$ErrorActionPreference = "Continue"
$BASE = "C:\dlp-stack"

Write-Host "=============================================" -ForegroundColor Green
Write-Host "  DLP-стенд: создание проекта" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green

# --------------- Очистка старого проекта ---------------
if (Test-Path $BASE) {
    Write-Host "Удаляем старый проект..." -ForegroundColor Yellow
    Set-Location $BASE
    docker compose down -v 2>$null
    docker stop squid icap-server ollama litellm open-webui mitmproxy 2>$null
    docker rm squid icap-server ollama litellm open-webui mitmproxy 2>$null
    Set-Location C:\
    Remove-Item -Recurse -Force $BASE -ErrorAction SilentlyContinue
}

# --------------- Создание структуры ---------------
New-Item -ItemType Directory -Force -Path "$BASE\mitmproxy", "$BASE\icap-server", "$BASE\litellm", `
    "$BASE\logs\mitmproxy", "$BASE\logs\icap\attachments", "$BASE\logs\litellm", "$BASE\logs\openwebui" | Out-Null

Write-Host "Структура папок создана." -ForegroundColor Green

# =============== .env файл ===============
Write-Host "Создаю .env файл..." -ForegroundColor Cyan
@'
# API Keys - замените на реальные значения перед использованием
OPENAI_API_KEY=sk-test-placeholder-replace-me
DEEPSEEK_API_KEY=sk-test-placeholder-replace-me
HUGGINGFACE_API_KEY=hf_test_placeholder-replace-me
VSEGPT_API_KEY=sk-test-placeholder-replace-me
OPENROUTER_API_KEY=sk-test-placeholder-replace-me
'@ | Out-File -FilePath "$BASE\.env" -Encoding utf8

Write-Host "⚠️  ВАЖНО: Отредактируйте $BASE\.env и добавьте реальные API-ключи!" -ForegroundColor Yellow

# Ограничим разрешения на .env (только Администраторы и текущий пользователь читают)
try {
    $user = $env:USERNAME
    icacls "$BASE\.env" /inheritance:r /grant:r "Administrators:F" /grant:r "$user:R" | Out-Null
    Write-Host ".env: права доступа настроены." -ForegroundColor Green
} catch {
    Write-Host "Не удалось настроить права .env автоматически: $_" -ForegroundColor Yellow
}

# =============== docker-compose.yml ===============
Write-Host "Создаю docker-compose.yml..." -ForegroundColor Cyan
@'
version: "3.8"
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
    container_name: mitmproxy
    command: ["mitmdump", "--mode", "regular", "--listen-port", "3128", "-s", "/home/mitmproxy/.mitmproxy/check_dlp.py", "-w", "/var/log/mitmproxy/traffic.log", "--set", "block_global=false"]
    ports: ["3128:3128"]
    volumes:
      - ./mitmproxy:/home/mitmproxy/.mitmproxy
      - ./logs/mitmproxy:/var/log/mitmproxy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3128/" ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  icap-server:
    build: ./icap-server
    container_name: icap-server
    ports: ["1344:1344"]
    volumes:
      - ./logs/icap:/var/log/icap
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "1344"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    ports: ["11434:11434"]
    volumes:
      - ollama-data:/root/.ollama
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags" ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s

  litellm:
    image: ghcr.io/berriai/litellm:latest
    container_name: litellm
    command: ["--config", "/app/config.yaml"]
    ports: ["4000:4000"]
    volumes:
      - ./litellm/config.yaml:/app/config.yaml
      - ./mitmproxy-ca.pem:/app/mitmproxy-ca.pem
      - ./logs/litellm:/var/log/litellm
    environment:
      - HTTP_PROXY=http://mitmproxy:3128
      - HTTPS_PROXY=http://mitmproxy:3128
      - NO_PROXY=ollama,localhost,127.0.0.1
      - SSL_CERT_FILE=/app/mitmproxy-ca.pem
      - REQUESTS_CA_BUNDLE=/app/mitmproxy-ca.pem
      - LITELLM_LOG=INFO
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
      - HUGGINGFACE_API_KEY=${HUGGINGFACE_API_KEY}
      - VSEGPT_API_KEY=${VSEGPT_API_KEY}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      - mitmproxy
      - icap-server
      - ollama
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health" ]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports: ["3000:8080"]
    environment:
      - OPENAI_API_BASE_URL=http://litellm:4000/v1
      - OPENAI_API_KEY=any-key
      - STREAMING_ENABLED=false
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      - litellm
    volumes:
      - open-webui-data:/app/backend/data
      - ./logs/openwebui:/var/log/openwebui
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/" ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

volumes:
  ollama-data:
  open-webui-data:
'@ | Out-File -FilePath "$BASE\docker-compose.yml" -Encoding utf8

# =============== mitmproxy/check_dlp.py ===============
Write-Host "Создаю скрипт mitmproxy..." -ForegroundColor Cyan
@'
import socket
import uuid

ICAP_HOST = "icap-server"
ICAP_PORT = 1344

# Отправка ICAP-запроса простым форматом (рабочая интеграция с нашим DLP-сервером)
def send_icap(body, service, request_id):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect((ICAP_HOST, ICAP_PORT))

        # Передаём request_id через заголовок
        icap_req = (
            service.upper() + " icap://" + ICAP_HOST + ":" + str(ICAP_PORT) + "/" + service + " ICAP/1.0\r\n"
            "Host: " + ICAP_HOST + ":" + str(ICAP_PORT) + "\r\n"
            "X-DLP-Request-ID: " + request_id + "\r\n"
            "Content-Length: " + str(len(body)) + "\r\n"
            "\r\n"
        ).encode() + body

        sock.sendall(icap_req)
        resp = b""
        while True:
            chunk = sock.recv(8192)
            if not chunk:
                break
            resp += chunk
        sock.close()
        return resp
    except Exception:
        return None


def parse_icap_response(resp):
    if not resp:
        return None, None
    try:
        header_end = resp.find(b"\r\n\r\n")
        if header_end == -1:
            return None, None
        header_block = resp[:header_end].decode(errors='ignore')
        body = resp[header_end+4:]
        status_line = header_block.splitlines()[0]
        parts = status_line.split()
        if len(parts) < 2:
            return None, None
        status_code = int(parts[1])
        return status_code, body
    except Exception:
        return None, None


def request(flow):
    if flow.request.content:
        request_id = str(uuid.uuid4())
        # Сохраняем в metadata для использования при response
        try:
            flow.metadata['dlp_request_id'] = request_id
        except Exception:
            pass

        resp = send_icap(flow.request.content, "reqmod", request_id)
        if resp:
            status, body = parse_icap_response(resp)
            if status == 403:
                from mitmproxy import http
                flow.response = http.Response.make(
                    403,
                    b'{"error":{"message":"DLP blocked","code":403}}',
                    {"Content-Type": "application/json"}
                )
            elif status == 200 and body:
                flow.request.content = body


def response(flow):
    if flow.response is None:
        return

    if not flow.response.content:
        return

    # Попытка получить request_id из metadata или заголовков
    request_id = None
    try:
        request_id = flow.metadata.get('dlp_request_id')
    except Exception:
        request_id = None

    if not request_id:
        try:
            request_id = flow.request.headers.get('X-DLP-Request-ID') or flow.request.headers.get('x-dlp-request-id')
        except Exception:
            request_id = None

    if not request_id:
        # Не удалось определить request_id, логируем и пропускаем
        try:
            print("[DLP] Missing request_id for flow, skipping response ICAP call")
        except Exception:
            pass
        return

    resp = send_icap(flow.response.content, "respmod", request_id)
    if resp:
        status, body = parse_icap_response(resp)
        if status == 403:
            from mitmproxy import http
            flow.response = http.Response.make(
                403,
                b'{"error":{"message":"DLP blocked","code":403}}',
                {"Content-Type": "application/json"}
            )
        elif status == 200 and body:
            flow.response.content = body
'@ | Out-File -FilePath "$BASE\mitmproxy\check_dlp.py" -Encoding utf8

# =============== icap-server/Dockerfile ===============
Write-Host "Создаю ICAP-сервер..." -ForegroundColor Cyan
@'
FROM python:3.11-slim
RUN pip install python-json-logger
COPY dlp_server.py /app/dlp_server.py
WORKDIR /app
EXPOSE 1344
CMD ["python", "dlp_server.py"]
'@ | Out-File -FilePath "$BASE\icap-server\Dockerfile" -Encoding utf8

# =============== icap-server/dlp_server.py ===============
Write-Host "Создаю ICAP DLP сервер..." -ForegroundColor Cyan
@'
import json, re, logging, os, socket, threading, base64
from pythonjsonlogger import jsonlogger
from datetime import datetime, timezone
import uuid

# Константы безопасности
LOG_DIR = os.environ.get("LOG_DIR", "/var/log/icap")
MAX_ATTACHMENT_SIZE = 20 * 1024 * 1024  # 20 МБ
MAX_REQUEST_SIZE = 100 * 1024 * 1024    # 100 МБ

os.makedirs(LOG_DIR, exist_ok=True)
ATTACHMENTS_DIR = os.path.join(LOG_DIR, "attachments")
os.makedirs(ATTACHMENTS_DIR, exist_ok=True)

# =============== Логирование ===============
logger = logging.getLogger()
logger.setLevel(logging.INFO)

handler = logging.StreamHandler()
handler.setFormatter(jsonlogger.JsonFormatter(
    "%(asctime)s %(levelname)s %(message)s %(funcName)s %(lineno)d",
    json_ensure_ascii=False
))
logger.addHandler(handler)

try:
    file_handler = logging.FileHandler(f"{LOG_DIR}/dlp.json")
    file_handler.setFormatter(jsonlogger.JsonFormatter(
        "%(asctime)s %(levelname)s %(message)s %(funcName)s %(lineno)d",
        json_ensure_ascii=False
    ))
    logger.addHandler(file_handler)
except Exception as e:
    logger.error(f"Failed to create file handler: {e}")

# =============== Правила и состояние ===============
ANONYMIZE_RULES = [
    (r"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b", "CARD"),
    (r"\b\d{3}-\d{2}-\d{2}\b", "SSN"),
    (r"\b[А-ЯЁ][а-яё]+\s[А-ЯЁ][а-яё]+\s[А-ЯЁ][а-яё]+\b", "FIO"),
    (r"\b[A-Z][a-z]+\s[A-Z][a-z]+\b", "NAME"),
    (r"\b\+?\d[\d\s\(\)\-]{6,}\b", "PHONE"),
    (r"\b[\w.-]+@[\w.-]+\.\w{2,}\b", "EMAIL"),
]

BLOCKED_WORDS = ["секретно", "конфиденциально", "конфиденциальность", "тайна"]

# Потокобезопасное хранилище сессий
sessions = {}
sessions_lock = threading.Lock()

# =============== Функции ===============
def now_iso():
    return datetime.utcnow().replace(tzinfo=timezone.utc).isoformat()

def log_event(event_type, **kwargs):
    """Логирование в JSON формате для SIEM"""
    event = {
        "event_type": event_type,
        "timestamp": now_iso(),
        **kwargs
    }
    logger.info(json.dumps(event, ensure_ascii=False))


def save_attachments(body, request_id):
    """Сохранение вложений с проверкой размера"""
    try:
        text = body.decode("utf-8", errors="ignore")
        for i, m in enumerate(re.finditer(
            r"data:(?P<mime>[^;]+);base64,(?P<b64>[A-Za-z0-9+/=]+)", text
        )):
            try:
                b64_data = m.group("b64")
                
                # Проверка размера перед декодированием
                estimated_size = int(len(b64_data) * 0.75)
                if estimated_size > MAX_ATTACHMENT_SIZE:
                    log_event("attachment_blocked", 
                        reason="size_exceeded",
                        request_id=request_id,
                        size=estimated_size,
                        max_size=MAX_ATTACHMENT_SIZE
                    )
                    continue
                
                file_data = base64.b64decode(b64_data)
                ext = m.group("mime").split("/")[-1].split("+")[0]
                # безопасное имя файла
                fname = f"{request_id}_{i}_{uuid.uuid4().hex}.{ext}"
                
                with open(os.path.join(ATTACHMENTS_DIR, fname), "wb") as f:
                    f.write(file_data)
                
                log_event("attachment_saved",
                    request_id=request_id,
                    filename=fname,
                    size=len(file_data)
                )
            except Exception as e:
                log_event("attachment_error",
                    request_id=request_id,
                    error=str(e),
                    index=i
                )
                continue
    except Exception as e:
        log_event("attachments_processing_error",
            request_id=request_id if 'request_id' in locals() else None,
            error=str(e)
        )


def anonymize_text(text, mapping):
    """Анонимизация текста"""
    for pattern, prefix in ANONYMIZE_RULES:
        try:
            def repl(m, prefix=prefix, mapping=mapping):
                original = m.group(0)
                idx = len(mapping) + 1
                placeholder = f"[{prefix}_{idx}]"
                mapping[placeholder] = original
                return placeholder
            text = re.sub(pattern, repl, text, flags=re.MULTILINE)
        except Exception as e:
            logger.error(f"Failed to apply pattern {pattern}: {e}")
            continue
    return text


def deanonymize_text(text, mapping):
    """Деанонимизация текста"""
    try:
        for placeholder, original in mapping.items():
            text = text.replace(placeholder, original)
    except Exception as e:
        logger.error(f"Failed to deanonymize: {e}")
    return text


def process_json_body(body, mode, mapping=None):
    """Обработка JSON/текста с анонимизацией"""
    if mapping is None:
        mapping = {}
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception as e:
        logger.debug(f"Not JSON body: {e}")
        text = body.decode("utf-8", errors="ignore")
        if mode == "anonymize":
            return anonymize_text(text, mapping).encode(), mapping
        else:
            return deanonymize_text(text, mapping).encode(), mapping

    def recursive_replace(obj):
        if isinstance(obj, str):
            return anonymize_text(obj, mapping) if mode == "anonymize" else deanonymize_text(obj, mapping)
        elif isinstance(obj, list):
            return [recursive_replace(item) for item in obj]
        elif isinstance(obj, dict):
            return {k: recursive_replace(v) for k, v in obj.items()}
        return obj

    try:
        new_data = recursive_replace(data)
        return json.dumps(new_data, ensure_ascii=False).encode(), mapping
    except Exception as e:
        logger.error(f"Failed to process JSON: {e}")
        return body, mapping


def parse_icap_request(data):
    """Парсинг ICAP запроса (поиск заголовков и тела)"""
    try:
        header_end = data.find(b"\r\n\r\n")
        if header_end == -1:
            raise ValueError("No header/body separator found")
        header_block = data[:header_end].decode(errors='ignore')
        lines = header_block.split("\r\n")
        request_line = lines[0]
        headers = {}
        for h in lines[1:]:
            if ":" in h:
                k, v = h.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        body = data[header_end+4:]
        return request_line, headers, body
    except Exception as e:
        logger.error(f"Failed to parse ICAP request: {e}")
        return "", {}, b""


def read_socket_fully(conn):
    """Полное чтение данных из сокета с лимитом размера"""
    chunks = []
    total_size = 0
    try:
        conn.settimeout(5)
        while total_size < MAX_REQUEST_SIZE:
            chunk = conn.recv(8192)
            if not chunk:
                break
            chunks.append(chunk)
            total_size += len(chunk)
        if total_size >= MAX_REQUEST_SIZE:
            log_event("request_too_large", size=total_size, max_size=MAX_REQUEST_SIZE)
            return None
        return b"".join(chunks)
    except Exception as e:
        logger.error(f"Error reading socket: {e}")
        return None


def handle_client(conn, addr):
    """Обработка клиента"""
    try:
        data = read_socket_fully(conn)
        if not data:
            return
        request_line, headers, body = parse_icap_request(data)
        service = "reqmod" if "reqmod" in request_line else "respmod"
        request_id = headers.get("x-dlp-request-id") or headers.get("X-DLP-Request-ID") or str(uuid.uuid4())

        if service == "reqmod":
            save_attachments(body, request_id)
            text = body.decode("utf-8", errors="ignore")
            blocked = False
            for word in BLOCKED_WORDS:
                if word.lower() in text.lower():
                    log_event("blocked", reason="keyword", keyword=word, request_id=request_id, client_ip=addr[0])
                    error_body = json.dumps({
                        "error": {
                            "message": "Заблокировано политиками информационной безопасности",
                            "type": "dlp_blocked",
                            "code": 403,
                            "request_id": request_id
                        }
                    }, ensure_ascii=False)
                    response = (
                        "ICAP/1.0 403 Forbidden\r\n"
                        "Server: DLP-Server/1.0\r\n"
                        "Connection: close\r\n"
                        f"Content-Length: {len(error_body)}\r\n"
                        "\r\n"
                        f"{error_body}"
                    )
                    conn.sendall(response.encode())
                    blocked = True
                    break
            if not blocked:
                mapping = {}
                new_body, mapping = process_json_body(body, "anonymize", mapping)
                if mapping:
                    with sessions_lock:
                        sessions[request_id] = {
                            "mapping": mapping,
                            "ts": datetime.utcnow().timestamp()
                        }
                    log_event("anonymized", request_id=request_id, fields_count=len(mapping))
                    response = (
                        "ICAP/1.0 200 OK\r\n"
                        "Server: DLP-Server/1.0\r\n"
                        "Connection: close\r\n"
                        f"Content-Length: {len(new_body)}\r\n"
                        "\r\n"
                    )
                    conn.sendall(response.encode() + new_body)
                else:
                    response = (
                        "ICAP/1.0 204 No Content\r\n"
                        "Server: DLP-Server/1.0\r\n"
                        "Connection: close\r\n"
                        "\r\n"
                    )
                    conn.sendall(response.encode())
        else:
            with sessions_lock:
                sess = sessions.pop(request_id, None)
            mapping = sess.get("mapping") if sess else {}
            if mapping:
                new_body, _ = process_json_body(body, "deanonymize", mapping)
                log_event("deanonymized", request_id=request_id, fields_count=len(mapping))
                response = (
                    "ICAP/1.0 200 OK\r\n"
                    "Server: DLP-Server/1.0\r\n"
                    "Connection: close\r\n"
                    f"Content-Length: {len(new_body)}\r\n"
                    "\r\n"
                )
                conn.sendall(response.encode() + new_body)
            else:
                response = (
                    "ICAP/1.0 204 No Content\r\n"
                    "Server: DLP-Server/1.0\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                )
                conn.sendall(response.encode())
    except Exception as e:
        log_event("client_error", client_ip=addr[0], error=str(e))
    finally:
        try:
            conn.close()
        except:
            pass


def reap_expired_sessions(ttl_seconds=300):
    """Периодическая очистка старых сессий (TTL)"""
    while True:
        try:
            now = datetime.utcnow().timestamp()
            with sessions_lock:
                keys = list(sessions.keys())
                for k in keys:
                    s = sessions.get(k)
                    if not s:
                        continue
                    if now - s.get("ts", 0) > ttl_seconds:
                        sessions.pop(k, None)
                        log_event("session_expired", request_id=k)
        except Exception:
            pass
        finally:
            import time
            time.sleep(60)


def main():
    """Главная функция"""
    # запустим фоновый reaper
    t = threading.Thread(target=reap_expired_sessions, args=(300,))
    t.daemon = True
    t.start()

    try:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", 1344))
        server.listen(100)
        log_event("server_started", port=1344)
        while True:
            try:
                conn, addr = server.accept()
                thread = threading.Thread(target=handle_client, args=(conn, addr))
                thread.daemon = True
                thread.start()
            except KeyboardInterrupt:
                break
            except Exception as e:
                log_event("accept_error", error=str(e))
                continue
    except Exception as e:
        log_event("server_error", error=str(e))
    finally:
        try:
            server.close()
        except:
            pass
        log_event("server_stopped")

if __name__ == "__main__":
    main()
'@ | Out-File -FilePath "$BASE\icap-server\dlp_server.py" -Encoding utf8

# =============== litellm/config.yaml ===============
Write-Host "Создаю конфиг LiteLLM..." -ForegroundColor Cyan
@'
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: ${OPENAI_API_KEY}
  - model_name: deepseek-chat
    litellm_params:
      model: deepseek/deepseek-chat
      api_key: ${DEEPSEEK_API_KEY}
  - model_name: vsegpt
    litellm_params:
      model: openai/gpt-4o-mini
      api_base: https://api.vsegpt.ru/v1
      api_key: ${VSEGPT_API_KEY}
  - model_name: openrouter
    litellm_params:
      model: openrouter/openai/gpt-4o
      api_key: ${OPENROUTER_API_KEY}
  - model_name: llama3-local
    litellm_params:
      model: ollama/llama3:8b
      api_base: http://ollama:11434
  - model_name: mistral-local
    litellm_params:
      model: ollama/mistral:7b
      api_base: http://ollama:11434
  - model_name: phi3-local
    litellm_params:
      model: ollama/phi3:mini
      api_base: http://ollama:11434

general_settings:
  cors: true
  default_stream: false
'@ | Out-File -FilePath "$BASE\litellm\config.yaml" -Encoding utf8

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  ПРОЕКТ СОЗДАН И НАСТРОЕН" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""

# =============== Запуск сервисов ===============
Write-Host "Запускаю сервисы..." -ForegroundColor Cyan
Set-Location $BASE

Write-Host "1. Запуск mitmproxy..." -ForegroundColor Yellow
docker compose up -d mitmproxy
Start-Sleep 15

# =============== Копирование сертификата ===============
Write-Host "2. Копирование сертификата mitmproxy..." -ForegroundColor Yellow
docker cp mitmproxy:/home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem "$BASE\mitmproxy-ca.pem" 2>$null
if (!(Test-Path "$BASE\mitmproxy-ca.pem")) {
    Write-Host "⚠️  Сертификат не найден, попытка через митм-конфиг..." -ForegroundColor Yellow
    Start-Sleep 5
    docker cp mitmproxy:/home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem "$BASE\mitmproxy-ca.pem" 2>$null
}

# =============== Подождём готовности сервисов (проверка health endpoints) ===============
function Wait-HttpReady([string]$url, [int]$timeoutSec = 120) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $timeoutSec) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($r -and $r.StatusCode -ge 200 -and $r.StatusCode -lt 400) {
                return $true
            }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

Write-Host "3. Ждём готовности mitmproxy..." -ForegroundColor Yellow
if (-not (Wait-HttpReady "http://localhost:3128/" 60)) { Write-Host "mitmproxy не отвечает" -ForegroundColor Yellow }

Write-Host "4. Запуск всех сервисов..." -ForegroundColor Yellow
docker compose up -d

Write-Host "5. Ожидание инициализации (30 сек)..." -ForegroundColor Yellow
Start-Sleep 30

# =============== Загрузка моделей Ollama (с проверкой готовности) ===============
Write-Host "6. Загрузка моделей Ollama..." -ForegroundColor Yellow
function Wait-Ollama([int]$timeoutSec = 180) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $timeoutSec) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($r -and $r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return $true }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

if (Wait-Ollama 180) {
    Write-Host "ollama доступен, загружаю модели..." -ForegroundColor Cyan
    docker exec ollama ollama pull llama3:8b 2>$null
    docker exec ollama ollama pull mistral:7b 2>$null
    docker exec ollama ollama pull phi3:mini 2>$null
} else {
    Write-Host "ollama не готов, пропускаю загрузку моделей" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  ✅ ПРОЕКТ ПОЛНОСТЬЮ ГОТОВ К РАБОТЕ" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "📋 ВАЖНЫЕ ШАГИ:" -ForegroundColor Yellow
Write-Host "  1. Отредактируйте: $BASE\.env" -ForegroundColor White
Write-Host "     Добавьте реальные API-ключи вместо placeholder" -ForegroundColor White
Write-Host "  2. Перезагрузите LiteLLM: docker compose restart litellm" -ForegroundColor White
Write-Host "  3. Откройте: http://localhost:3000" -ForegroundColor White
Write-Host ""
Write-Host "📊 ЛОГИ И МОНИТОРИНГ:" -ForegroundColor Yellow
Write-Host "  DLP (JSON):    $BASE\logs\icap\dlp.json" -ForegroundColor White
Write-Host "  Mitmproxy:     $BASE\logs\mitmproxy\traffic.log" -ForegroundColor White
Write-Host "  LiteLLM:       $BASE\logs\litellm\" -ForegroundColor White
Write-Host "  Open WebUI:    $BASE\logs\openwebui\" -ForegroundColor White
Write-Host "  Вложения:      $BASE\logs\icap\attachments\" -ForegroundColor White
Write-Host ""
Write-Host "🔧 ПОЛЕЗНЫЕ КОМАНДЫ:" -ForegroundColor Yellow
Write-Host "  Логи DLP в реальном времени:" -ForegroundColor White
Write-Host "    Get-Content '$BASE\logs\icap\dlp.json' -Wait" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Статус сервисов:" -ForegroundColor White
Write-Host "    docker compose ps" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Остановка всех сервисов:" -ForegroundColor White
Write-Host "    docker compose down" -ForegroundColor Cyan
Write-Host ""
