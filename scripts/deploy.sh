#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:?Image URI required}"
COMMIT="${2:?Commit SHA required}"
VERSION="${COMMIT:0:8}"
REGISTRY=862330373261.dkr.ecr.ap-south-1.amazonaws.com

[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  { echo "Invalid commit SHA"; exit 1; }

[[ "$IMAGE" == "$REGISTRY/aws-blue-green:"* ]] ||
  { echo "Unexpected image repository"; exit 1; }

exec 8>/opt/aws-blue-green/deploy.lock
flock -n 8 || { echo "Another deployment is running"; exit 1; }

# Identify the current release before changing any containers.
curl -fsS --max-time 5 http://127.0.0.1/ready |
  jq -e '.status == "ready"' >/dev/null

ACTIVE=$(curl -fsS --max-time 5 http://127.0.0.1/version |
  jq -er '.slot')

case "$ACTIVE" in
  blue) TARGET=green; PORT=8082 ;;
  green) TARGET=blue; PORT=8081 ;;
  *) echo "Cannot identify active slot"; exit 1 ;;
esac

grep -Fq "proxy_pass http://bg-$ACTIVE:8000;" \
  /opt/aws-blue-green/nginx/default.conf ||
  { echo "Active slot and Nginx configuration disagree"; exit 1; }

echo "Active: $ACTIVE. Deploying $VERSION to $TARGET."

aws ecr get-login-password --region ap-south-1 |
  docker login --username AWS --password-stdin "$REGISTRY"

docker pull "$IMAGE"

# Verify the image was built from the requested commit.
REVISION=$(docker image inspect \
  --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
  "$IMAGE")

[ "$REVISION" = "$COMMIT" ] ||
  { echo "Image commit label does not match"; exit 1; }

# Use the exact local image that was verified.
IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE")

if docker container inspect "bg-$TARGET" >/dev/null 2>&1; then
  docker rm -f "bg-$TARGET"
fi

docker run -d \
  --name "bg-$TARGET" \
  --network bg-network \
  --restart unless-stopped \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  -p "127.0.0.1:$PORT:8000" \
  -e APP_VERSION="$VERSION" \
  -e DEPLOYMENT_SLOT="$TARGET" \
  -e GIT_COMMIT="$COMMIT" \
  "$IMAGE_ID"

READY=false
for attempt in {1..30}; do
  if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/ready" |
     jq -e '.status == "ready"' >/dev/null; then
    READY=true
    break
  fi
  sleep 2
done

if [ "$READY" != true ]; then
  docker logs --tail 50 "bg-$TARGET"
  echo "Candidate failed readiness; traffic remains on $ACTIVE."
  exit 1
fi

bash /opt/aws-blue-green/switch.sh "$TARGET" "$VERSION" "$COMMIT"
