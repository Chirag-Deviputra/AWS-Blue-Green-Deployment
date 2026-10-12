#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="${1:?Specify blue or green}"
VERSION="${2:?Specify expected version}"
COMMIT="${3:?Specify expected commit}"

case "$TARGET" in
  blue) PORT=8081 ;;
  green) PORT=8082 ;;
  *) echo "Target must be blue or green"; exit 1 ;;
esac

exec 9>/opt/aws-blue-green/switch.lock
flock -n 9 || { echo "Another switch is running"; exit 1; }

CONFIG=/opt/aws-blue-green/nginx/default.conf
PUBLIC=http://127.0.0.1

check() {
  local base="$1" slot="$2" version="$3" commit="$4"
  curl -fsS --max-time 3 "$base/ready" |
    jq -e '.status == "ready"' >/dev/null || return 1
  curl -fsS --max-time 3 "$base/version" |
    jq -e --arg s "$slot" --arg v "$version" --arg c "$commit" \
      '.slot == $s and .version == $v and .commit == $c' \
      >/dev/null || return 1
}

PREVIOUS=$(curl -fsS --max-time 3 "$PUBLIC/version")
OLD_SLOT=$(jq -er '.slot' <<<"$PREVIOUS")
OLD_VERSION=$(jq -er '.version' <<<"$PREVIOUS")
OLD_COMMIT=$(jq -er '.commit' <<<"$PREVIOUS")

case "$OLD_SLOT" in
  blue|green) ;;
  *) echo "Unknown active slot"; exit 1 ;;
esac

if [ "$TARGET" = "$OLD_SLOT" ]; then
  echo "$TARGET is already active"
  exit 1
fi

grep -Fq "proxy_pass http://bg-$OLD_SLOT:8000;" "$CONFIG" ||
  { echo "Nginx configuration disagrees with active slot"; exit 1; }

check "$PUBLIC" "$OLD_SLOT" "$OLD_VERSION" "$OLD_COMMIT" ||
  { echo "Current release is unhealthy"; exit 1; }

check "http://127.0.0.1:$PORT" "$TARGET" "$VERSION" "$COMMIT" ||
  { echo "Candidate checks failed; traffic unchanged"; exit 1; }

BACKUP=$(mktemp /opt/aws-blue-green/nginx-backup.XXXXXX)
cp "$CONFIG" "$BACKUP"
ARMED=1

cleanup() {
  local result=$?
  trap - EXIT
  set +e

  if [ "$ARMED" = 1 ]; then
    echo "Switch failed. Restoring $OLD_SLOT..."
    if cp "$BACKUP" "$CONFIG" &&
       docker exec bg-proxy nginx -t &&
       docker exec bg-proxy nginx -s reload; then
      for attempt in {1..10}; do
        if check "$PUBLIC" "$OLD_SLOT" "$OLD_VERSION" "$OLD_COMMIT"; then
          echo "ROLLBACK VERIFIED: $OLD_SLOT / $OLD_VERSION"
          rm -f "$BACKUP"
          exit 1
        fi
        sleep 1
      done
    fi
    echo "ROLLBACK NOT VERIFIED. Backup retained: $BACKUP"
    exit 1
  fi

  rm -f "$BACKUP"
  exit "$result"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sed -i "s/bg-$OLD_SLOT:8000/bg-$TARGET:8000/" "$CONFIG"
docker exec bg-proxy nginx -t
docker exec bg-proxy nginx -s reload

echo "Traffic switched. Monitoring $TARGET..."
FAILURES=0
for attempt in {1..30}; do
  sleep 2
  if check "$PUBLIC" "$TARGET" "$VERSION" "$COMMIT"; then
    FAILURES=0
    echo "Check $attempt/30: PASS"
  else
    FAILURES=$((FAILURES + 1))
    echo "Check $attempt/30: FAIL"
    if [ "$FAILURES" -ge 3 ]; then
      exit 1
    fi
  fi
done

check "$PUBLIC" "$TARGET" "$VERSION" "$COMMIT"
ARMED=0
echo "DEPLOYMENT VERIFIED: $TARGET / $VERSION"
