import json
import re
import logging
import os
import socket
import threading
import base64
import uuid
from datetime import datetime, timezone
from pythonjsonlogger import jsonlogger

# ICAP DLP Server with full Encapsulated framing support

LOG_DIR = os.environ.get("LOG_DIR", "/var/log/icap")
MAX_ATTACHMENT_SIZE = 20 * 1024 * 1024  # 20 MB
MAX_REQUEST_SIZE = 200 * 1024 * 1024    # 200 MB

os.makedirs(LOG_DIR, exist_ok=True)
ATTACHMENTS_DIR = os.path.join(LOG_DIR, "attachments")
os.makedirs(ATTACHMENTS_DIR, exist_ok=True)

# Logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(jsonlogger.JsonFormatter('%(asctime)s %(levelname)s %(message)s', json_ensure_ascii=False))
logger.addHandler(handler)
try:
    file_handler = logging.FileHandler(f"{LOG_DIR}/dlp.json")
    file_handler.setFormatter(jsonlogger.JsonFormatter('%(asctime)s %(levelname)s %(message)s', json_ensure_ascii=False))
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
sessions_lock = threading.Lock()


def now_iso():
    return datetime.utcnow().replace(tzinfo=timezone.utc).isoformat()


def log_event(event_type, **kwargs):
    event = {"event_type": event_type, "timestamp": now_iso(), **kwargs}
    logger.info(json.dumps(event, ensure_ascii=False))


# ---------- Low-level socket readers ----------

def recv_exact(conn, n):
    parts = []
    remaining = n
    while remaining > 0:
        chunk = conn.recv(remaining)
        if not chunk:
            raise ConnectionError("socket closed while reading exact bytes")
        parts.append(chunk)
        remaining -= len(chunk)
    return b"".join(parts)


def recv_until(conn, sep=b"\r\n\r\n", max_bytes=MAX_REQUEST_SIZE):
    buf = b""
    while True:
        if len(buf) > max_bytes:
            raise ValueError("header too large")
        chunk = conn.recv(4096)
        if not chunk:
            break
        buf += chunk
        idx = buf.find(sep)
        if idx != -1:
            return buf, idx
    return buf, -1


def read_icap_message(conn):
    # Read headers block
    header_buf, idx = recv_until(conn, b"\r\n\r\n")
    if idx == -1:
        return None
    header_block = header_buf[:idx].decode(errors="ignore")
    rest = header_buf[idx+4:]

    lines = header_block.split("\r\n")
    request_line = lines[0]
    headers = {}
    for h in lines[1:]:
        if ":" in h:
            k, v = h.split(":", 1)
            headers[k.strip().lower()] = v.strip()

    # Determine how many bytes of ICAP body to read
    body = b""
    if 'content-length' in headers:
        try:
            length = int(headers['content-length'])
        except Exception:
            length = 0
        # rest may already contain part of body
        need = length - len(rest)
        body = rest
        if need > 0:
            body += recv_exact(conn, need)
    elif headers.get('transfer-encoding', '').lower() == 'chunked':
        # read chunked body from rest + conn
        body = rest + read_chunked_from_buffer_and_socket(conn, rest)
    else:
        # No body
        body = rest

    return request_line, headers, body


# ---------- ICAP chunked reader ----------

def read_chunked_from_buffer_and_socket(conn, initial_buf=b""):
    buf = initial_buf
    out = b""
    while True:
        # need to ensure we have a line with chunk size
        while b"\r\n" not in buf:
            part = conn.recv(4096)
            if not part:
                raise ConnectionError("socket closed while reading chunk-size")
            buf += part
        line_end = buf.find(b"\r\n")
        size_line = buf[:line_end].decode(errors='ignore').strip()
        try:
            size = int(size_line.split(';')[0], 16)
        except Exception:
            raise ValueError(f"Invalid chunk size: {size_line}")
        buf = buf[line_end+2:]
        if size == 0:
            # consume trailing CRLF after 0-chunk and possible trailer until CRLF CRLF
            # there might be trailer headers - read until CRLF CRLF
            # ensure buf contains at least CRLF CRLF
            while b"\r\n\r\n" not in buf:
                part = conn.recv(4096)
                if not part:
                    break
                buf += part
            # exclude the trailing headers from returned body
            return out
        # ensure buf has size + 2 (CRLF)
        while len(buf) < size + 2:
            part = conn.recv(4096)
            if not part:
                raise ConnectionError("socket closed while reading chunk data")
            buf += part
        out += buf[:size]
        buf = buf[size+2:]


# ---------- HTTP message helpers (for encapsulated parts) ----------

def split_http_header_and_body(data_bytes):
    idx = data_bytes.find(b"\r\n\r\n")
    if idx == -1:
        return data_bytes, b""
    hdr = data_bytes[:idx+4]
    body = data_bytes[idx+4:]
    return hdr, body


def parse_http_headers(header_bytes):
    try:
        s = header_bytes.decode(errors='ignore')
        lines = s.split('\r\n')
        start_line = lines[0]
        headers = {}
        for h in lines[1:]:
            if not h:
                continue
            if ':' in h:
                k, v = h.split(':', 1)
                headers[k.strip().lower()] = v.strip()
        return start_line, headers
    except Exception:
        return "", {}


def dechunk_http_body(body_bytes):
    # body_bytes contains HTTP chunked data (chunks+trailers). Convert to raw bytes
    out = b""
    buf = body_bytes
    while True:
        idx = buf.find(b"\r\n")
        if idx == -1:
            raise ValueError("Invalid chunked encoding: missing size line")
        size_line = buf[:idx].decode(errors='ignore').split(';')[0].strip()
        try:
            size = int(size_line, 16)
        except Exception:
            raise ValueError("Invalid chunk size")
        buf = buf[idx+2:]
        if size == 0:
            # skip any trailer up to CRLF CRLF
            term = buf.find(b"\r\n\r\n")
            if term != -1:
                return out
            else:
                return out
        if len(buf) < size + 2:
            raise ValueError("Incomplete chunk data")
        out += buf[:size]
        buf = buf[size+2:]


def chunk_http_body(body_bytes, chunk_size=4096):
    out = b""
    idx = 0
    while idx < len(body_bytes):
        take = min(chunk_size, len(body_bytes) - idx)
        out += f"{take:x}\r\n".encode() + body_bytes[idx:idx+take] + b"\r\n"
        idx += take
    out += b"0\r\n\r\n"
    return out


# ---------- ICAP Encapsulated parsing ----------

def parse_encapsulated(header_value, icap_body):
    # header_value like: "req-hdr=0, req-body=137"
    parts = {}
    for part in header_value.split(','):
        if '=' in part:
            k, v = part.strip().split('=', 1)
            try:
                parts[k.strip().lower()] = int(v)
            except Exception:
                parts[k.strip().lower()] = 0
    if not parts:
        return {}
    # sort by offset
    items = sorted(parts.items(), key=lambda x: x[1])
    result = {}
    for i, (name, offset) in enumerate(items):
        start = offset
        end = len(icap_body)
        if i + 1 < len(items):
            end = items[i+1][1]
        piece = icap_body[start:end]
        result[name] = piece
    return result


# ---------- Body processing (anonymization etc.) ----------

def anonymize_text(text, mapping):
    for pattern, prefix in ANONYMIZE_RULES:
        def repl(m, prefix=prefix, mapping=mapping):
            original = m.group(0)
            idx = len(mapping) + 1
            placeholder = f"[{prefix}_{idx}]"
            mapping[placeholder] = original
            return placeholder
        try:
            text = re.sub(pattern, repl, text, flags=re.MULTILINE)
        except Exception:
            continue
    return text


def deanonymize_text(text, mapping):
    for placeholder, original in mapping.items():
        text = text.replace(placeholder, original)
    return text


def process_json_body_bytes(body_bytes, mode, mapping=None):
    if mapping is None:
        mapping = {}
    try:
        data = json.loads(body_bytes.decode('utf-8'))
    except Exception:
        text = body_bytes.decode('utf-8', errors='ignore')
        if mode == 'anonymize':
            return anonymize_text(text, mapping).encode('utf-8'), mapping
        else:
            return deanonymize_text(text, mapping).encode('utf-8'), mapping

    def recursive_replace(obj):
        if isinstance(obj, str):
            return anonymize_text(obj, mapping) if mode == 'anonymize' else deanonymize_text(obj, mapping)
        if isinstance(obj, list):
            return [recursive_replace(x) for x in obj]
        if isinstance(obj, dict):
            return {k: recursive_replace(v) for k, v in obj.items()}
        return obj

    try:
        new_data = recursive_replace(data)
        return json.dumps(new_data, ensure_ascii=False).encode('utf-8'), mapping
    except Exception:
        return body_bytes, mapping


# ---------- Main ICAP logic ----------

def build_icap_response_with_modified_http(original_http_hdr_bytes, modified_http_body_bytes, http_start_line, http_headers):
    # Rebuild HTTP header: update Content-Length, remove Transfer-Encoding
    headers = dict(http_headers)
    headers.pop('transfer-encoding', None)
    headers['content-length'] = str(len(modified_http_body_bytes))
    # Reconstruct header block
    hdr_lines = [http_start_line]
    for k, v in headers.items():
        hdr_lines.append(f"{k}: {v}")
    hdr_block = "\r\n".join(hdr_lines) + "\r\n\r\n"
    hdr_bytes = hdr_block.encode('utf-8')
    resp_body = hdr_bytes + modified_http_body_bytes
    return resp_body, hdr_bytes


def handle_icap_request(request_line, headers, icap_body, conn, addr):
    method = request_line.split()[0].lower()
    enc = headers.get('encapsulated', '')
    parts = parse_encapsulated(enc, icap_body) if enc else {}

    # pick reqmod or respmod
    if method == 'reqmod':
        req_hdr = parts.get('req-hdr', b'')
        req_body_part = parts.get('req-body', b'') or b''

        # parse http header and body
        http_hdr_bytes, http_body_bytes = split_http_header_and_body(req_hdr + req_body_part)
        http_start_line, http_headers = parse_http_headers(http_hdr_bytes)

        # if body is chunked according to http headers, dechunk
        http_body_raw = http_body_bytes
        if http_headers.get('transfer-encoding', '').lower() == 'chunked':
            try:
                http_body_raw = dechunk_http_body(http_body_bytes)
            except Exception as e:
                log_event('dechunk_error', error=str(e), request_id=headers.get('x-dlp-request-id'), client_ip=addr[0])
                http_body_raw = http_body_bytes

        # Run DLP checks: blocked words
        text = http_body_raw.decode('utf-8', errors='ignore')
        for word in BLOCKED_WORDS:
            if word.lower() in text.lower():
                log_event('blocked', reason='keyword', keyword=word, client_ip=addr[0], request_id=headers.get('x-dlp-request-id'))
                error_body = json.dumps({
                    'error': {
                        'message': 'Заблокировано политиками информационной безопасности',
                        'type': 'dlp_blocked',
                        'code': 403
                    }
                }, ensure_ascii=False)
                resp = (
                    'ICAP/1.0 403 Forbidden\r\n'
                    'Server: DLP-Server/1.0\r\n'
                    'Connection: close\r\n'
                    f'Content-Length: {len(error_body.encode("utf-8"))}\r\n'
                    '\r\n'
                    f'{error_body}'
                )
                conn.sendall(resp.encode('utf-8'))
                return

        # anonymize JSON body if possible
        new_body, mapping = process_json_body_bytes(http_body_raw, 'anonymize', {})
        if mapping:
            request_id = headers.get('x-dlp-request-id') or str(uuid.uuid4())
            with sessions_lock:
                sessions[request_id] = {'mapping': mapping, 'ts': datetime.utcnow().timestamp()}
            log_event('anonymized', request_id=request_id, fields_count=len(mapping), client_ip=addr[0])

            # rebuild HTTP message with new body
            resp_body_bytes, resp_hdr_bytes = build_icap_response_with_modified_http(http_hdr_bytes, new_body, http_start_line, http_headers)
            # Build ICAP response with Encapsulated: req-hdr=0, req-body=<len(req_hdr_bytes)>
            enc_hdr = f'req-hdr=0, req-body={len(resp_hdr_bytes)}'
            icap_headers = (
                'ICAP/1.0 200 OK\r\n'
                f'Server: DLP-Server/1.0\r\n'
                f'Encapsulated: {enc_hdr}\r\n'
                f'Content-Length: {len(resp_body_bytes)}\r\n'
                'Connection: close\r\n'
                '\r\n'
            )
            conn.sendall(icap_headers.encode('utf-8') + resp_body_bytes)
            return
        else:
            # no changes
            resp = (
                'ICAP/1.0 204 No Content\r\n'
                'Server: DLP-Server/1.0\r\n'
                'Connection: close\r\n'
                '\r\n'
            )
            conn.sendall(resp.encode('utf-8'))
            return

    elif method == 'respmod':
        res_hdr = parts.get('res-hdr', b'')
        res_body_part = parts.get('res-body', b'') or b''

        http_hdr_bytes, http_body_bytes = split_http_header_and_body(res_hdr + res_body_part)
        http_start_line, http_headers = parse_http_headers(http_hdr_bytes)

        http_body_raw = http_body_bytes
        if http_headers.get('transfer-encoding', '').lower() == 'chunked':
            try:
                http_body_raw = dechunk_http_body(http_body_bytes)
            except Exception as e:
                log_event('dechunk_error', error=str(e), request_id=headers.get('x-dlp-request-id'), client_ip=addr[0])
                http_body_raw = http_body_bytes

        # Run DLP checks on response body
        text = http_body_raw.decode('utf-8', errors='ignore')
        for word in BLOCKED_WORDS:
            if word.lower() in text.lower():
                log_event('blocked', reason='keyword', keyword=word, client_ip=addr[0], request_id=headers.get('x-dlp-request-id'))
                error_body = json.dumps({
                    'error': {
                        'message': 'Заблокировано политиками информационной безопасности',
                        'type': 'dlp_blocked',
                        'code': 403
                    }
                }, ensure_ascii=False)
                resp = (
                    'ICAP/1.0 403 Forbidden\r\n'
                    'Server: DLP-Server/1.0\r\n'
                    'Connection: close\r\n'
                    f'Content-Length: {len(error_body.encode("utf-8"))}\r\n'
                    '\r\n'
                    f'{error_body}'
                )
                conn.sendall(resp.encode('utf-8'))
                return

        new_body, mapping = process_json_body_bytes(http_body_raw, 'deanonymize', {})
        if mapping:
            request_id = headers.get('x-dlp-request-id') or str(uuid.uuid4())
            log_event('deanonymized', request_id=request_id, fields_count=len(mapping), client_ip=addr[0])
            resp_body_bytes, resp_hdr_bytes = build_icap_response_with_modified_http(http_hdr_bytes, new_body, http_start_line, http_headers)
            enc_hdr = f'res-hdr=0, res-body={len(resp_hdr_bytes)}'
            icap_headers = (
                'ICAP/1.0 200 OK\r\n'
                f'Server: DLP-Server/1.0\r\n'
                f'Encapsulated: {enc_hdr}\r\n'
                f'Content-Length: {len(resp_body_bytes)}\r\n'
                'Connection: close\r\n'
                '\r\n'
            )
            conn.sendall(icap_headers.encode('utf-8') + resp_body_bytes)
            return
        else:
            resp = (
                'ICAP/1.0 204 No Content\r\n'
                'Server: DLP-Server/1.0\r\n'
                'Connection: close\r\n'
                '\r\n'
            )
            conn.sendall(resp.encode('utf-8'))
            return

    else:
        # Unsupported ICAP method
        resp = (
            'ICAP/1.0 405 Method Not Allowed\r\n'
            'Server: DLP-Server/1.0\r\n'
            'Connection: close\r\n'
            '\r\n'
        )
        conn.sendall(resp.encode('utf-8'))
        return


# ---------- Connection handler ----------

def handle_client(conn, addr):
    try:
        # read full ICAP message
        message = read_icap_message(conn)
        if not message:
            return
        request_line, headers, body = message
        try:
            log_event('icap_request_received', method=request_line.split()[0], client_ip=addr[0], request_id=headers.get('x-dlp-request-id'))
        except Exception:
            pass
        try:
            handle_icap_request(request_line, headers, body, conn, addr)
        except Exception as e:
            log_event('icap_processing_error', error=str(e), client_ip=addr[0])
            try:
                conn.sendall(b'ICAP/1.0 500 Internal Server Error\r\nConnection: close\r\n\r\n')
            except Exception:
                pass
    except Exception as e:
        log_event('client_error', client_ip=addr[0] if addr else None, error=str(e))
    finally:
        try:
            conn.close()
        except Exception:
            pass


# ---------- Session reaper ----------

def reap_expired_sessions(ttl_seconds=300):
    while True:
        try:
            now = datetime.utcnow().timestamp()
            with sessions_lock:
                keys = list(sessions.keys())
                for k in keys:
                    s = sessions.get(k)
                    if not s:
                        continue
                    if now - s.get('ts', 0) > ttl_seconds:
                        sessions.pop(k, None)
                        log_event('session_expired', request_id=k)
        except Exception:
            pass
        finally:
            import time
            time.sleep(60)


def main():
    t = threading.Thread(target=reap_expired_sessions, args=(300,))
    t.daemon = True
    t.start()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', 1344))
    server.listen(100)
    log_event('server_started', port=1344)
    try:
        while True:
            conn, addr = server.accept()
            thread = threading.Thread(target=handle_client, args=(conn, addr))
            thread.daemon = True
            thread.start()
    except KeyboardInterrupt:
        pass
    except Exception as e:
        log_event('server_error', error=str(e))
    finally:
        try:
            server.close()
        except Exception:
            pass
        log_event('server_stopped')


if __name__ == '__main__':
    main()
