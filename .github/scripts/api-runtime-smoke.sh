#!/usr/bin/env bash
# Disposable GitHub-hosted CI test. Never point this at production data.
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
scratch="$(mktemp -d "${RUNNER_TEMP%/}/rustdesk-api-smoke.XXXXXXXX")"
container=""
volume=""
volume_created=0
arch="not-started"
stage="initializing"
last_log=""

print_diagnostic_log() {
  python3 - "$1" <<'PYLOG'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(0)
for line in path.read_text(errors="replace").splitlines()[-80:]:
    if re.search(r"password|passwd|secret|token|authorization|credential", line, re.I):
        print("diagnostic: [potential credential line omitted]")
    else:
        # Prefix untrusted output so it cannot start a workflow command.
        print("diagnostic: " + line)
PYLOG
}

cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    echo "FAIL: architecture=$arch stage=$stage exit=$rc" >&2
    if [[ -n "$last_log" ]]; then
      print_diagnostic_log "$last_log" >&2 || true
    fi
  fi
  if [[ -n "$container" ]]; then
    if (( rc != 0 )); then
      docker inspect --format 'State={{.State.Status}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}' "$container" 2>/dev/null || true
      # Initialization logs can contain a generated administrator password.
      docker logs --tail 80 "$container" >"$scratch/failure.log" 2>&1 || true
      print_diagnostic_log "$scratch/failure.log" >&2 || true
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

start_api() {
  stage="start-api"
  last_log=""
  container="rdapi-${arch}-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
  docker run --detach --pull=never --name "$container" \
    --platform "linux/$arch" \
    --memory 512m --cpus 1 --cap-drop ALL --security-opt no-new-privileges \
    --read-only \
    --tmpfs /app/runtime:rw,noexec,nosuid,nodev,uid=10001,gid=10001,mode=0700 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,uid=10001,gid=10001,mode=0700 \
    --publish 127.0.0.1::21114 \
    --mount "type=volume,source=$volume,target=/app/data" \
    --env RUSTDESK_API_LANG=en \
    --env RUSTDESK_API_APP_WEB_CLIENT=0 \
    --env RUSTDESK_API_APP_REGISTER=false \
    --env RUSTDESK_API_APP_SHOW_SWAGGER=0 \
    --env RUSTDESK_API_LDAP_ENABLE=false \
    --env RUSTDESK_API_GORM_TYPE=sqlite \
    --env RUSTDESK_API_GIN_API_ADDR=0.0.0.0:21114 \
    --env RUSTDESK_API_RUSTDESK_ID_SERVER=127.0.0.1:21116 \
    --env RUSTDESK_API_RUSTDESK_RELAY_SERVER=127.0.0.1:21117 \
    --env RUSTDESK_API_RUSTDESK_API_SERVER=http://127.0.0.1:21114 \
    --env RUSTDESK_API_RUSTDESK_KEY_FILE=/dev/null \
    --env "RUSTDESK_API_JWT_KEY=$jwt_key" \
    "$platform_image" >/dev/null

  stage="api-http-checks"
  last_log="$scratch/curl.err"
  local address deadline ready=0
  address="$(docker port "$container" 21114/tcp)"
  if [[ ! "$address" =~ ^127\.0\.0\.1:[0-9]+$ ]]; then
    echo "Unexpected port binding: $address" >&2
    return 1
  fi
  deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container")" != "true" ]]; then
      echo "API exited before its HTTP endpoint became ready ($arch)." >&2
      return 1
    fi
    if curl --noproxy '*' --silent --show-error --fail \
      --connect-timeout 2 --max-time 3 \
      "http://$address/api/" -o "$scratch/index.json" 2>"$scratch/curl.err"; then
      ready=1
      break
    fi
    sleep 2
  done
  if (( ready == 0 )); then
    echo "API readiness deadline exceeded ($arch)." >&2
    return 1
  fi
  curl --noproxy '*' --silent --show-error --fail \
    --connect-timeout 2 --max-time 5 \
    "http://$address/api/version" -o "$scratch/version.json"
  python3 - "$scratch/index.json" "$scratch/version.json" <<'PY'
import json, pathlib, sys
index = json.loads(pathlib.Path(sys.argv[1]).read_text())
version = json.loads(pathlib.Path(sys.argv[2]).read_text())
if index.get("code") != 0 or index.get("data") != "Hello Gwen":
    raise SystemExit("Unexpected response from GET /api/")
if version.get("code") != 0 or not isinstance(version.get("data"), str) or not version["data"].strip():
    raise SystemExit("Unexpected response from GET /api/version")
print("PASS: API HTTP routes and application response bodies")
PY
}

snapshot_db() {
  local phase="$1" snapshot="$scratch/$arch-$1"
  stage="sqlite-$phase"
  last_log=""
  # Copy the complete directory after stopping, not a live SQLite file.
  docker stop --time 20 "$container" >/dev/null
  mkdir -p "$snapshot"
  docker cp "$container:/app/data/." "$snapshot/"
  python3 - "$snapshot" "$phase" "$scratch/$arch-admin-fingerprint" <<'PY'
import hashlib, json, pathlib, sqlite3, sys
path = pathlib.Path(sys.argv[1]) / "rustdeskapi.db"
if not path.is_file() or path.stat().st_size == 0:
    raise SystemExit("SQLite database missing or empty")
with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as db:
    if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        raise SystemExit("SQLite integrity check failed")
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not {"users", "versions"}.issubset(tables):
        raise SystemExit("Expected migration tables were not created")
    admins = db.execute("SELECT id, username, password FROM users WHERE username=?", ("admin",)).fetchall()
    if len(admins) != 1 or not admins[0][2]:
        raise SystemExit("Initialized administrator row is missing or invalid")
    if db.execute("SELECT COUNT(*) FROM versions").fetchone()[0] < 1:
        raise SystemExit("Migration version record missing")
# Compare a fingerprint without printing the password hash or any credentials.
fingerprint = hashlib.sha256(json.dumps(admins).encode()).hexdigest()
record = pathlib.Path(sys.argv[3])
if sys.argv[2] == "first":
    record.write_text(fingerprint)
else:
    if record.read_text() != fingerprint:
        raise SystemExit("Administrator data changed across container recreation")
print("PASS: SQLite integrity, migrations and administrator persistence check (" + sys.argv[2] + ")")
PY
  docker rm --volumes "$container" >/dev/null
  container=""
}

# Select platform-specific child manifests from THIS build's immutable index.
# A legacy Docker image store cannot keep both platforms under one index ref.
stage="read-image-index"
last_log="$scratch/image-index.err"
timeout 60s docker buildx imagetools inspect --raw "$SMOKE_IMAGE" \
  >"$scratch/image-index.json" 2>"$last_log"
stage="validate-image-index"
last_log=""
python3 - "$scratch/image-index.json" "${SMOKE_IMAGE%@*}" >"$scratch/platform-images.tsv" <<'PYINDEX'
import json, pathlib, re, sys
index = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(index, dict) or not isinstance(index.get("manifests"), list):
    raise SystemExit("Expected a multi-platform image index")
allowed_types = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}
selected = []
for arch in ("amd64", "arm64"):
    matches = []
    for manifest in index["manifests"]:
        if not isinstance(manifest, dict):
            raise SystemExit("Invalid manifest descriptor")
        platform = manifest.get("platform") or {}
        annotations = manifest.get("annotations") or {}
        if annotations.get("vnd.docker.reference.type") == "attestation-manifest":
            continue
        if manifest.get("mediaType") not in allowed_types:
            continue
        if platform.get("os") == "linux" and platform.get("architecture") == arch:
            supported_variants = ("", "v8") if arch == "arm64" else ("", "v1")
            if platform.get("variant", "") in supported_variants:
                matches.append(manifest.get("digest", ""))
    if len(matches) != 1 or not re.fullmatch(r"sha256:[a-f0-9]{64}", matches[0]):
        raise SystemExit("Expected exactly one valid image manifest for linux/" + arch)
    selected.append((arch, matches[0]))
if selected[0][1] == selected[1][1]:
    raise SystemExit("Different architectures unexpectedly share one manifest")
for arch, digest in selected:
    print(arch + "\t" + sys.argv[2] + "@" + digest)
PYINDEX

while IFS=$'\t' read -r arch platform_image; do
  echo "Testing linux/$arch: $platform_image"
  stage="pull-image"
  last_log="$scratch/pull-$arch.log"
  timeout 180s docker pull --platform "linux/$arch" "$platform_image" >"$last_log" 2>&1
  echo "PASS: linux/$arch image pulled"

  stage="inspect-local-platform"
  last_log="$scratch/inspect-$arch.log"
  timeout 30s docker image inspect --format '{{.Os}}/{{.Architecture}}' \
    "$platform_image" >"$last_log" 2>&1
  actual_platform="$(cat "$last_log")"
  if [[ "$actual_platform" != "linux/$arch" ]]; then
    echo "Pulled image platform does not match linux/$arch." >&2
    exit 1
  fi
  echo "PASS: linux/$arch local image platform verified"

  stage="inspect-image-user"
  last_log="$scratch/user-$arch.log"
  timeout 30s docker image inspect --format '{{.Config.User}}' \
    "$platform_image" >"$last_log" 2>&1
  image_user="$(cat "$last_log")"
  if [[ "$image_user" != "10001:10001" ]]; then
    echo "Image user is not the expected unprivileged UID/GID." >&2
    exit 1
  fi
  echo "PASS: linux/$arch image runs as UID/GID 10001:10001"

  stage="help-command"
  last_log="$scratch/help-$arch.txt"
  container="rdapi-help-${arch}-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
  # Separate commands preserve docker's exit status; no early-closing grep pipe.
  timeout 30s docker run --rm --pull=never --name "$container" \
    --platform "linux/$arch" "$platform_image" --help >"$last_log" 2>&1
  container=""
  stage="check-help-output"
  grep -Fq "RUSTDESK API SERVER" "$last_log"
  echo "PASS: linux/$arch --help exited successfully"
  last_log=""
  stage="create-test-volume"

  volume="rdapi-smoke-${arch}-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "Refusing to use an existing volume." >&2
    exit 1
  fi
  docker volume create --label purpose=rustdesk-api-ci-smoke "$volume" >/dev/null
  volume_created=1
  jwt_key="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  start_api
  snapshot_db first
  start_api
  snapshot_db second
  stage="remove-test-volume"
  docker volume rm "$volume" >/dev/null
  volume_created=0
  volume=""
  echo "PASS: linux/$arch runtime smoke test"
done <"$scratch/platform-images.tsv"

echo "PASS: both image architectures passed the bounded runtime checks"
