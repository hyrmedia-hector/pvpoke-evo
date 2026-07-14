#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
: "${R2_BUCKET_NAME:=pvpoke-data}"
: "${DATA_VERSION:?DATA_VERSION is required}"
: "${R2_UPLOAD_CONCURRENCY:=4}"
: "${R2_UPLOAD_ATTEMPTS:=5}"

manifest_file="$(mktemp)"
count_file="$(mktemp)"
lock_file="$(mktemp)"
marker_file="$(mktemp)"
marker_log="$(mktemp)"
trap 'rm -f "$manifest_file" "$count_file" "$lock_file" "$marker_file" "$marker_log"' EXIT

if wrangler r2 object get "$R2_BUCKET_NAME/versions/$DATA_VERSION/v1/catalog.json" \
  --remote --file "$marker_file" >"$marker_log" 2>&1; then
  echo "Immutable candidate $DATA_VERSION already has its completion marker; skipping all writes."
  exit 0
fi
if ! grep -Fq 'The specified key does not exist.' "$marker_log"; then
  echo "Unable to determine whether immutable candidate $DATA_VERSION already exists." >&2
  cat "$marker_log" >&2
  exit 1
fi

python3 - "$manifest_file" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
with output.open("w", encoding="utf-8") as stream:
    for path in sorted(Path("dist").rglob("*")):
        if not path.is_file() or path.name == "current.json" or path.as_posix() == "dist/v1/catalog.json":
            continue
        relative = path.relative_to("dist").as_posix()
        if path.suffix == ".json":
            content_type = "application/json; charset=utf-8"
        elif path.suffix == ".php":
            content_type = "text/plain; charset=utf-8"
        else:
            content_type = "application/octet-stream"
        stream.write(f"{path}\t{relative}\t{content_type}\n")
PY

total="$(( $(wc -l < "$manifest_file" | tr -d ' ') + 1 ))"
echo "Uploading $total immutable objects to R2"
echo 0 > "$count_file"

upload_one() {
  local line="$1"
  local file relative content_type attempt log_path delay count
  IFS=$'\t' read -r file relative content_type <<< "$line"
  log_path="$(mktemp)"
  attempt=1
  while [ "$attempt" -le "$R2_UPLOAD_ATTEMPTS" ]; do
    if wrangler r2 object put "$R2_BUCKET_NAME/versions/$DATA_VERSION/$relative" \
      --remote --file "$file" --content-type "$content_type" >"$log_path" 2>&1; then
      break
    fi
    if grep -Eq '429: Too Many Requests|code":10058' "$log_path" && [ "$attempt" -lt "$R2_UPLOAD_ATTEMPTS" ]; then
      delay="$((attempt * attempt * 5))"
      echo "R2 throttled $relative on attempt $attempt; retrying in ${delay}s"
      sleep "$delay"
      attempt="$((attempt + 1))"
      continue
    fi
    cat "$log_path"
    rm -f "$log_path"
    return 1
  done
  rm -f "$log_path"
  {
    flock 9
    count="$(( $(cat "$count_file") + 1 ))"
    echo "$count" > "$count_file"
    if [ $((count % 25)) -eq 0 ] || [ "$count" -eq "$total" ]; then
      echo "Uploaded $count/$total objects"
    fi
  } 9>"$lock_file"
}
export -f upload_one
export R2_BUCKET_NAME DATA_VERSION R2_UPLOAD_ATTEMPTS count_file lock_file total
xargs -r -P "$R2_UPLOAD_CONCURRENCY" -n 1 -d '\n' bash -c 'upload_one "$1"' _ < "$manifest_file"

# The catalog is the immutable completion marker. It is written only after every payload object
# succeeds, so retries can distinguish an incomplete staging prefix from a complete bundle.
upload_one $'dist/v1/catalog.json\tv1/catalog.json\tapplication/json; charset=utf-8'

uploaded="$(cat "$count_file")"
if [ "$uploaded" != "$total" ]; then
  echo "Upload incomplete: $uploaded/$total" >&2
  exit 1
fi
