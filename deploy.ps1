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
    docker-compose down -v 2>$null
    docker stop squid icap-server ollama litellm open-webui mitmproxy 2>$null
    docker rm squid icap-server ollama litellm open-webui mitmproxy 2>$null
    Set-Location C:\
    Remove-Item -Recurse -Force $BASE -ErrorAction SilentlyContinue
}

# --------------- Создание структуры ---------------
New-Item -ItemType Directory -Force -Path "$BASE\mitmproxy", "$BASE\icap-server", "$BASE\litellm", `
    "$BASE\logs\mitmproxy", "$BASE\logs\icap\attachments", "$BASE\logs\litellm", "$BASE\logs\openwebui" | Out-Null

Write-Host "Структура папок создана." -ForegroundColor Green

# =============== docker-compose.yml ===============
Write-Host "Создаю docker-compose.yml..." -ForegroundColor Cyan
@"
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
      - OPENAI_API_KEY=`${OPENAI_API_KEY:-sk-test-placeholder}
      - DEEPSEEK_API_KEY=`${DEEPSEEK_API_KEY:-sk-test-placeholder}
      - HUGGINGFACE_API_KEY=`${HUGGINGFACE_API_KEY:-hf_test_placeholder}
      - VSEGPT_API_KEY=`${VSEGPT_API_KEY:-sk-test-placeholder}
      - OPENROUTER_API_KEY=`${OPENROUTER_API_KEY:-sk-test-placeholder}
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

volumes:
  ollama-data:
  open-webui-data:
"@ | Out-File -FilePath "$BASE\docker-compose.yml" -Encoding utf8

# =============== mitmproxy/check_dlp.py ===============
Write-Host "Создаю скрипт mitmproxy..." -ForegroundColor Cyan
@"
import socket

ICAP_HOST = "icap-server"
ICAP_PORT = 1344

def send_icap(body, service):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect((ICAP_HOST, ICAP_PORT))
        icap_req = (
            service.upper() + " icap://" + ICAP_HOST + ":" + str(ICAP_PORT) + "/" + service + " ICAP/1.0\r\n"
            "Host: " + ICAP_HOST + ":" + str(ICAP_PORT) + "\r\n"
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
    except Exception as e:
        return None

def parse_icap_response(resp):
    if not resp:
        return None, None
    try:
        header_end = resp.index(b"\r\n\r\n")
        body = resp[header_end+4:]
        status_line = resp[:header_end].decode()
        status_code = int(status_line.split(" ")[1])
        return status_code, body
    except Exception as e:
        return None, None

def request(flow):
    if flow.request.content:
        resp = send_icap(flow.request.content, "reqmod")
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
    if flow.response and flow.response.content:
        resp = send_icap(flow.response.content, "respmod")
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
"@ | Out-File -FilePath "$BASE\mitmproxy\check_dlp.py" -Encoding utf8

# =============== icap-server/Dockerfile ===============
Write-Host "Создаю ICAP-сервер..." -ForegroundColor Cyan
@"
FROM python:3.11-slim
RUN pip install python-json-logger
COPY dlp_server.py /app/dlp_server.py
WORKDIR /app
EXPOSE 1344
CMD ["python", "dlp_server.py"]
"@ | Out-File -FilePath "$BASE\icap-server\Dockerfile" -Encoding utf8

# =============== icap-server/dlp_server.py ===============
@"
import json, re, hashlib, logging, os, socket, threading, base64
from pythonjsonlogger import jsonlogger

LOG_DIR = os.environ.get("LOG_DIR", "/var/log/icap")
os.makedirs(LOG_DIR, exist_ok=True)
ATTACHMENTS_DIR = os.path.join(LOG_DIR, "attachments")
os.makedirs(ATTACHMENTS_DIR, exist_ok=True)

logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(levelname)s %(message)s", json_ensure_ascii=False))
logger.addHandler(handler)

try:
    file_handler = logging.FileHandler(f"{LOG_DIR}/dlp.json")
    file_handler.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(levelname)s %(message)s", json_ensure_ascii=False))
    logger.addHandler(file_handler)
except Exception as e:
    logger.error(f"Failed to create file handler: {e}")

ANONYMIZE_RULES = [
    (r"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b", "CARD"),
    (r"\b\d{3}-\d{2}-\d{2}\b", "SSN"),
    (r"\b[А-ЯЁ][а-яё]+\s[А-ЯЁ][а-яё]+\s[А-ЯЁ][а-яё]+\b", "FIO"),
    (r"\b[A-Z][a-z]+\s[A-Z][a-z]+\b", "NAME"),
    (r"\b\+?\d[\d\s\(\)\-]{6,}\b", "PHONE"),
    (r"\b[\w.-]+@[\w.-]+\.\w{2,}\b", "EMAIL"),
]
BLOCKED_WORDS = ["секретно", "конфиденциально", "конфиденциальность", "тайна"]
sessions = {}

def save_attachments(body, request_id):
    try:
        text = body.decode("utf-8", errors="ignore")
        for i, m in enumerate(re.finditer(r"data:(?P<mime>[^;]+);base64,(?P<b64>[A-Za-z0-9+/=]+)", text)):
            try:
                file_data = base64.b64decode(m.group("b64"))
                ext = m.group("mime").split("/")[-1].split("+")[0]
                fname = f"{request_id}_{i}.{ext}"
                with open(os.path.join(ATTACHMENTS_DIR, fname), "wb") as f:
                    f.write(file_data)
                logger.info(f"Saved attachment: {fname}")
            except Exception as e:
                logger.error(f"Failed to decode/save attachment {i}: {e}")
                continue
    except Exception as e:
        logger.error(f"Failed to process attachments: {e}")

def anonymize_text(text, mapping):
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
    try:
        for placeholder, original in mapping.items():
            text = text.replace(placeholder, original)
    except Exception as e:
        logger.error(f"Failed to deanonymize: {e}")
    return text

def process_json_body(body, mode, mapping=None):
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
    try:
        lines = data.split(b"\r\n")
        request_line = lines[0].decode()
        headers = {}
        body_start = 0
        for i, line in enumerate(lines[1:], 1):
            if line == b"":
                body_start = i + 1
                break
            if b":" in line:
                key, value = line.decode().split(":", 1)
                headers[key.strip().lower()] = value.strip()
        body = b"\r\n".join(lines[body_start:]) if body_start < len(lines) else b""
        return request_line, headers, body
    except Exception as e:
        logger.error(f"Failed to parse ICAP request: {e}")
        return "", {}, b""

def handle_client(conn, addr):
    try:
        data = conn.recv(65536)
        if not data:
            return
        request_line, headers, body = parse_icap_request(data)
        service = "reqmod" if "reqmod" in request_line else "respmod"
        req_id = hashlib.md5(body).hexdigest()

        if service == "reqmod":
            save_attachments(body, req_id)
            text = body.decode("utf-8", errors="ignore")
            blocked = False
            for word in BLOCKED_WORDS:
                if word.lower() in text.lower():
                    logger.warning(f"BLOCKED by word: {word}")
                    error_body = json.dumps({
                        "error": {
                            "message": "Заблокировано политиками информационной безопасности",
                            "type": "dlp_blocked",
                            "code": 403
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
                    sessions[req_id] = mapping
                    logger.info(f"Anonymized: {mapping}")
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
            mapping = sessions.pop(req_id, {})
            if mapping:
                new_body, _ = process_json_body(body, "deanonymize", mapping)
                logger.info("Deanonymized")
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
        logger.error(f"Error handling client: {e}")
    finally:
        try:
            conn.close()
        except:
            pass

def main():
    try:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", 1344))
        server.listen(100)
        logger.info("ICAP DLP Server listening on port 1344")
        while True:
            try:
                conn, addr = server.accept()
                thread = threading.Thread(target=handle_client, args=(conn, addr))
                thread.daemon = True
                thread.start()
            except KeyboardInterrupt:
                break
            except Exception as e:
                logger.error(f"Error accepting connection: {e}")
                continue
    except Exception as e:
        logger.error(f"Server error: {e}")
    finally:
        try:
            server.close()
        except:
            pass

if __name__ == "__main__":
    main()
"@ | Out-File -FilePath "$BASE\icap-server\dlp_server.py" -Encoding utf8

# =============== litellm/config.yaml ===============
Write-Host "Создаю конфиг LiteLLM..." -ForegroundColor Cyan
@"
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: `${OPENAI_API_KEY:-sk-test-placeholder}
  - model_name: deepseek-chat
    litellm_params:
      model: deepseek/deepseek-chat
      api_key: `${DEEPSEEK_API_KEY:-sk-test-placeholder}
  - model_name: vsegpt
    litellm_params:
      model: openai/gpt-4o-mini
      api_base: https://api.vsegpt.ru/v1
      api_key: `${VSEGPT_API_KEY:-sk-test-placeholder}
  - model_name: openrouter
    litellm_params:
      model: openrouter/openai/gpt-4o
      api_key: `${OPENROUTER_API_KEY:-sk-test-placeholder}
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
"@ | Out-File -FilePath "$BASE\litellm\config.yaml" -Encoding utf8

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  ПРОЕКТ СОЗДАН В $BASE" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Дальнейшие шаги:" -ForegroundColor Yellow
Write-Host "  1. cd $BASE" -ForegroundColor White
Write-Host "  2. docker-compose up -d" -ForegroundColor White
Write-Host "  3. Ждать 3-5 минут" -ForegroundColor White
Write-Host "  4. Открыть http://localhost:3000" -ForegroundColor White
Write-Host ""
Write-Host "Логи:" -ForegroundColor Yellow
Write-Host "  DLP:         $BASE\logs\icap\dlp.json" -ForegroundColor White
Write-Host "  Mitmproxy:   $BASE\logs\mitmproxy\traffic.log" -ForegroundColor White
Write-Host "  LiteLLM:     $BASE\logs\litellm\" -ForegroundColor White
Write-Host "  Open WebUI:  $BASE\logs\openwebui\" -ForegroundColor White
Write-Host "  Файлы:       $BASE\logs\icap\attachments\" -ForegroundColor White
