#!/usr/bin/env bash
# Black-box API contract derived from the official RustDesk 1.4.9 Flutter client.
# Disposable GitHub-hosted CI only. Never point this at production data.
set -Eeuo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]; then
  echo "This test is restricted to disposable GitHub-hosted runners." >&2
  exit 2
fi
: "${SMOKE_IMAGE:?Provide the image reference from the current build digest}"
: "${RUNNER_TEMP:?Missing runner temporary directory}"
if [[ ! "$SMOKE_IMAGE" =~ ^ghcr\.io/x0204x/rustdesk-api@sha256:[a-f0-9]{64}$ ]]; then
  echo "Expected this fork's GHCR image pinned by a complete digest." >&2
  exit 2
fi
for tool in docker curl python3 timeout; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done

umask 077
scratch="$(mktemp -d "${RUNNER_TEMP%/}/rustdesk-client-contract.XXXXXXXX")"
container=""
volume=""
volume_created=0
stage="initializing"
last_log=""

print_diagnostic_log() {
  python3 - "$1" <<'PYLOG'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(0)
for line in path.read_text(errors="replace").splitlines()[-80:]:
    if re.search(r"password|passwd|secret|token|authorization|credential|access_token", line, re.I):
        print("diagnostic: [potential credential line omitted]")
    else:
        print("diagnostic: " + line)
PYLOG
}

cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    echo "FAIL: RustDesk 1.4.9 contract stage=$stage exit=$rc" >&2
    if [[ -n "$last_log" ]]; then
      print_diagnostic_log "$last_log" >&2 || true
    fi
  fi
  if [[ -n "$container" ]]; then
    if (( rc != 0 )); then
      docker inspect --format 'State={{.State.Status}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}' "$container" 2>/dev/null || true
      docker logs --tail 80 "$container" >"$scratch/container.log" 2>&1 || true
      print_diagnostic_log "$scratch/container.log" >&2 || true
    fi
    docker rm --force --volumes "$container" >/dev/null 2>&1 || true
  fi
  if (( volume_created == 1 )); then
    docker volume rm "$volume" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$scratch"
  exit "$rc"
}
trap cleanup EXIT

# Select the amd64 child manifest from THIS build's immutable OCI index.
stage="select-amd64-manifest"
last_log="$scratch/image-index.err"
timeout 60s docker buildx imagetools inspect --raw "$SMOKE_IMAGE" \
  >"$scratch/image-index.json" 2>"$last_log"
platform_image="$(python3 - "$scratch/image-index.json" "${SMOKE_IMAGE%@*}" <<'PYINDEX'
import json, pathlib, re, sys
index = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(index, dict) or not isinstance(index.get("manifests"), list):
    raise SystemExit("Expected a multi-platform image index")
matches = []
for manifest in index["manifests"]:
    if not isinstance(manifest, dict):
        continue
    platform = manifest.get("platform") or {}
    annotations = manifest.get("annotations") or {}
    if annotations.get("vnd.docker.reference.type") == "attestation-manifest":
        continue
    if platform.get("os") == "linux" and platform.get("architecture") == "amd64":
        digest = manifest.get("digest", "")
        if re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            matches.append(digest)
if len(matches) != 1:
    raise SystemExit("Expected exactly one linux/amd64 image manifest")
print(sys.argv[2] + "@" + matches[0])
PYINDEX
)"
last_log=""

stage="pull-amd64-image"
last_log="$scratch/pull.log"
timeout 180s docker pull --platform linux/amd64 "$platform_image" >"$last_log" 2>&1
last_log=""
echo "PASS: RustDesk 1.4.9 contract image selected by immutable amd64 digest"

volume="rdapi-contract-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
if docker volume inspect "$volume" >/dev/null 2>&1; then
  echo "Refusing to use an existing volume." >&2
  exit 1
fi
docker volume create --label purpose=rustdesk-api-client-contract "$volume" >/dev/null
volume_created=1

jwt_key="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
admin_password="$(python3 -c 'import secrets; print(secrets.token_hex(12))')"

common_env=(
  --env RUSTDESK_API_LANG=en
  --env RUSTDESK_API_APP_WEB_CLIENT=0
  --env RUSTDESK_API_APP_REGISTER=false
  --env RUSTDESK_API_APP_SHOW_SWAGGER=0
  --env RUSTDESK_API_LDAP_ENABLE=false
  --env RUSTDESK_API_GORM_TYPE=sqlite
  --env RUSTDESK_API_GIN_API_ADDR=0.0.0.0:21114
  --env RUSTDESK_API_LOGGER_PATH=/app/runtime/log.txt
  --env RUSTDESK_API_RUSTDESK_ID_SERVER=127.0.0.1:21116
  --env RUSTDESK_API_RUSTDESK_RELAY_SERVER=127.0.0.1:21117
  --env RUSTDESK_API_RUSTDESK_API_SERVER=http://127.0.0.1:21114
  --env RUSTDESK_API_RUSTDESK_KEY_FILE=/dev/null
  --env RUSTDESK_API_RUSTDESK_PERSONAL=1
  --env "RUSTDESK_API_JWT_KEY=$jwt_key"
)
security_args=(
  --memory 512m
  --cpus 1
  --cap-drop ALL
  --security-opt no-new-privileges
  --read-only
  --tmpfs /app/runtime:rw,noexec,nosuid,nodev,uid=10001,gid=10001,mode=0700
  --tmpfs /tmp:rw,noexec,nosuid,nodev,uid=10001,gid=10001,mode=0700
)

# Initialize the disposable database and replace the random bootstrap password.
# All command output remains private because bootstrap logs may contain credentials.
stage="reset-disposable-admin-password"
last_log="$scratch/reset-admin.log"
timeout 90s docker run --rm --pull=never \
  --platform linux/amd64 \
  "${security_args[@]}" \
  --mount "type=volume,source=$volume,target=/app/data" \
  "${common_env[@]}" \
  "$platform_image" reset-admin-pwd "$admin_password" >"$last_log" 2>&1
last_log=""
echo "PASS: disposable administrator initialized without exposing credentials"

stage="start-api"
container="rdapi-contract-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
docker run --detach --pull=never --name "$container" \
  --platform linux/amd64 \
  "${security_args[@]}" \
  --publish 127.0.0.1::21114 \
  --mount "type=volume,source=$volume,target=/app/data" \
  "${common_env[@]}" \
  "$platform_image" >/dev/null

address="$(docker port "$container" 21114/tcp)"
if [[ ! "$address" =~ ^127\.0\.0\.1:[0-9]+$ ]]; then
  echo "Unexpected API port binding." >&2
  exit 1
fi

stage="wait-api"
last_log="$scratch/readiness.err"
deadline=$((SECONDS + 90))
ready=0
while (( SECONDS < deadline )); do
  if [[ "$(docker inspect --format '{{.State.Running}}' "$container")" != "true" ]]; then
    echo "API exited before becoming ready." >&2
    exit 1
  fi
  if curl --noproxy '*' --silent --show-error --fail \
    --connect-timeout 2 --max-time 3 \
    "http://$address/api/" -o "$scratch/index.json" 2>"$last_log"; then
    ready=1
    break
  fi
  sleep 2
done
if (( ready == 0 )); then
  echo "API readiness deadline exceeded." >&2
  exit 1
fi
last_log=""

# RustDesk 1.4.9 calls GET /api/login-options before or around account login.
stage="login-options"
status="$(curl --noproxy '*' --silent --show-error \
  --connect-timeout 2 --max-time 5 \
  --output "$scratch/login-options.json" --write-out '%{http_code}' \
  "http://$address/api/login-options")"
if [[ "$status" != "200" ]]; then
  echo "GET /api/login-options returned HTTP $status" >&2
  exit 1
fi
python3 - "$scratch/login-options.json" <<'PY'
import json, pathlib, sys
body = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(body, list) or not all(isinstance(x, str) for x in body):
    raise SystemExit("login-options must be a JSON array of strings")
common = [x for x in body if x.startswith("common-oidc/")]
if len(common) != 1:
    raise SystemExit("login-options must contain exactly one common-oidc entry")
providers = json.loads(common[0][len("common-oidc/"):])
if not isinstance(providers, list):
    raise SystemExit("common-oidc payload must decode to a JSON array")
print("PASS: RustDesk 1.4.9 GET /api/login-options contract")
PY

# Match the 1.4.9 LoginRequest JSON field names without printing credentials.
ADMIN_PASSWORD="$admin_password" python3 - "$scratch/login-request.json" <<'PY'
import json, os, pathlib, sys
payload = {
    "username": "admin",
    "password": os.environ["ADMIN_PASSWORD"],
    "id": "ci-client-149",
    "uuid": "ci-contract-149",
    "autoLogin": True,
    "type": "account",
    "deviceInfo": {"name": "GitHub Actions", "os": "Windows", "type": "desktop"},
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload, separators=(",", ":")))
PY

stage="login"
status="$(curl --noproxy '*' --silent --show-error \
  --connect-timeout 2 --max-time 10 \
  --header 'Content-Type: application/json' \
  --data-binary @"$scratch/login-request.json" \
  --output "$scratch/login.json" --write-out '%{http_code}' \
  "http://$address/api/login")"
if [[ "$status" != "200" ]]; then
  echo "POST /api/login returned HTTP $status" >&2
  exit 1
fi
python3 - "$scratch/login.json" "$scratch/token" <<'PY'
import json, pathlib, sys
body = json.loads(pathlib.Path(sys.argv[1]).read_text())
if body.get("type") != "access_token":
    raise SystemExit("login response type is not access_token")
token = body.get("access_token")
if not isinstance(token, str) or not token:
    raise SystemExit("login response has no access_token")
user = body.get("user")
if not isinstance(user, dict) or user.get("name") != "admin":
    raise SystemExit("login response user payload is incompatible")
pathlib.Path(sys.argv[2]).write_text(token)
print("PASS: RustDesk 1.4.9 POST /api/login response contract")
PY

token="$(cat "$scratch/token")"
printf '%s' '{"id":"ci-client-149","uuid":"ci-contract-149"}' >"$scratch/current-user-request.json"

stage="current-user"
status="$(curl --noproxy '*' --silent --show-error \
  --connect-timeout 2 --max-time 10 \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $token" \
  --data-binary @"$scratch/current-user-request.json" \
  --output "$scratch/current-user.json" --write-out '%{http_code}' \
  "http://$address/api/currentUser")"
if [[ "$status" != "200" ]]; then
  echo "POST /api/currentUser returned HTTP $status" >&2
  exit 1
fi
python3 - "$scratch/current-user.json" <<'PY'
import json, pathlib, sys
body = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(body, dict) or body.get("name") != "admin":
    raise SystemExit("currentUser payload is incompatible")
if "status" not in body or "is_admin" not in body:
    raise SystemExit("currentUser payload is missing client-consumed fields")
print("PASS: RustDesk 1.4.9 POST /api/currentUser contract")
PY

# RustDesk 1.4.9 personal/shared address-book bootstrap.
for endpoint in personal settings; do
  stage="address-book-$endpoint"
  status="$(curl --noproxy '*' --silent --show-error \
    --connect-timeout 2 --max-time 10 \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data-binary '{}' \
    --output "$scratch/ab-$endpoint.json" --write-out '%{http_code}' \
    "http://$address/api/ab/$endpoint")"
  if [[ "$status" != "200" ]]; then
    echo "POST /api/ab/$endpoint returned HTTP $status" >&2
    exit 1
  fi
done
python3 - "$scratch/ab-personal.json" "$scratch/ab-settings.json" <<'PY'
import json, pathlib, sys
personal = json.loads(pathlib.Path(sys.argv[1]).read_text())
settings = json.loads(pathlib.Path(sys.argv[2]).read_text())
if not isinstance(personal, dict) or not isinstance(personal.get("guid"), str) or not personal["guid"]:
    raise SystemExit("personal address-book response has no guid")
if personal.get("rule") != 3:
    raise SystemExit("personal address-book response has unexpected rule")
if not isinstance(settings, dict) or not isinstance(settings.get("max_peer_one_ab"), int):
    raise SystemExit("address-book settings response is incompatible")
print("PASS: RustDesk 1.4.9 personal address-book bootstrap contract")
PY

stage="shared-address-books"
status="$(curl --noproxy '*' --silent --show-error \
  --connect-timeout 2 --max-time 10 \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $token" \
  --data-binary '{}' \
  --output "$scratch/shared-profiles.json" --write-out '%{http_code}' \
  "http://$address/api/ab/shared/profiles?current=1&pageSize=100")"
if [[ "$status" != "200" ]]; then
  echo "POST /api/ab/shared/profiles returned HTTP $status" >&2
  exit 1
fi
python3 - "$scratch/shared-profiles.json" <<'PY'
import json, pathlib, sys
body = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(body, dict) or not isinstance(body.get("total"), int) or not isinstance(body.get("data"), list):
    raise SystemExit("shared address-book profile response is incompatible")
print("PASS: RustDesk 1.4.9 shared address-book profile contract")
PY

# Group panel calls made by RustDesk 1.4.9 after current-user refresh.
for spec in \
  'device-group/accessible?current=1&pageSize=100' \
  'users?current=1&pageSize=100&accessible=&status=1' \
  'peers?current=1&pageSize=100&accessible=&status=1'; do
  safe_name="${spec%%\?*}"
  safe_name="${safe_name//\//-}"
  stage="group-$safe_name"
  status="$(curl --noproxy '*' --silent --show-error \
    --connect-timeout 2 --max-time 10 \
    --header "Authorization: Bearer $token" \
    --output "$scratch/group-$safe_name.json" --write-out '%{http_code}' \
    "http://$address/api/$spec")"
  if [[ "$status" != "200" ]]; then
    echo "GET /api/${spec%%\?*} returned HTTP $status" >&2
    exit 1
  fi
  python3 - "$scratch/group-$safe_name.json" "$safe_name" <<'PY'
import json, pathlib, sys
body = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(body, dict) or not isinstance(body.get("total"), int) or not isinstance(body.get("data"), list):
    raise SystemExit(sys.argv[2] + " response is incompatible")
print("PASS: RustDesk 1.4.9 group endpoint contract: " + sys.argv[2])
PY
done

stage="logout"
status="$(curl --noproxy '*' --silent --show-error \
  --connect-timeout 2 --max-time 10 \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $token" \
  --data-binary @"$scratch/current-user-request.json" \
  --output "$scratch/logout.json" --write-out '%{http_code}' \
  "http://$address/api/logout")"
if [[ "$status" != "200" ]]; then
  echo "POST /api/logout returned HTTP $status" >&2
  exit 1
fi

stage="logout-invalidates-token"
status="$(curl --noproxy '*' --silent --show-error \
  --connect-timeout 2 --max-time 10 \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $token" \
  --data-binary @"$scratch/current-user-request.json" \
  --output "$scratch/after-logout.json" --write-out '%{http_code}' \
  "http://$address/api/currentUser")"
if [[ "$status" != "401" ]]; then
  echo "Logged-out access token unexpectedly remained usable (HTTP $status)." >&2
  exit 1
fi
echo "PASS: RustDesk 1.4.9 logout invalidates the access token"

docker rm --force --volumes "$container" >/dev/null
container=""
docker volume rm "$volume" >/dev/null
volume_created=0
volume=""

echo "PASS: RustDesk 1.4.9 API compatibility contract"
