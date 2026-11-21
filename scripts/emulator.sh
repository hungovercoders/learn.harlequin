#!/usr/bin/env bash
# Run AWS Emulator, and stand the beer sales job's infrastructure up on it.
#
#   scripts/emulator.sh start  run the emulator and leave it running; give it a terminal of its own
#   scripts/emulator.sh up     apply infra/ to the emulator, upload the events, run dbt build
#
# start uses an aws-emulator already on your PATH. Without one, on Linux and WSL it
# downloads the pinned version into .tools/ and checks AWS's signature; on macOS and
# Windows, where there is no native package, it runs the emulator in Docker.
# The emulator forgets everything when it stops, so run up again after a restart.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/emulator_env.sh
source scripts/emulator_env.sh
BUCKET=beer-sales-local

# Pinned so everyone tests against the same emulator. Versions:
# https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/versions.json
EMULATOR_VERSION="${EMULATOR_VERSION:-1.0.545}"
EMULATOR_BASE=https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS
# The AWS publishing key that signs the emulator packages (from its user guide).
EMULATOR_KEY=98BCF336A3BE53B734E967C52E5BF49BD940F624
EMULATOR_BIN=.tools/aws-emulator/opt/aws-emulator/bin/aws-emulator

install() {
  local arch tmp package
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) echo "No AWS Emulator package for $(uname -m)"; exit 1 ;;
  esac
  if ! command -v dpkg-deb >/dev/null || ! command -v gpgv >/dev/null; then
    echo "Installing needs dpkg-deb and gpgv. Otherwise install AWS Emulator yourself so aws-emulator is on your PATH."
    exit 1
  fi
  tmp="$(mktemp -d)"
  package="aws-emulator_${EMULATOR_VERSION}-1_${arch}.deb"
  echo "Downloading AWS Emulator $EMULATOR_VERSION"
  curl -fsSLo "$tmp/emulator.deb" "$EMULATOR_BASE/$package"
  curl -fsSLo "$tmp/emulator.deb.sig" "$EMULATOR_BASE/$package.sig"
  curl -fsSLo "$tmp/key.asc" https://downloads.aws.com/keys/gpg/current.asc
  if ! gpg --show-keys --with-colons "$tmp/key.asc" 2>/dev/null | grep -q "^fpr:::::::::$EMULATOR_KEY:"; then
    echo "The AWS publishing key does not have the expected fingerprint"; exit 1
  fi
  gpg --dearmor < "$tmp/key.asc" > "$tmp/key.gpg"
  # The signature must be good and made by that key, not by another the key file also holds.
  gpgv --status-fd 1 --keyring "$tmp/key.gpg" "$tmp/emulator.deb.sig" "$tmp/emulator.deb" > "$tmp/status" 2>/dev/null
  if ! grep -aEq "^\\[GNUPG:\\] VALIDSIG ($EMULATOR_KEY .*|.* $EMULATOR_KEY)\$" "$tmp/status"; then
    echo "The package is not signed by the AWS publishing key"; exit 1
  fi
  rm -rf .tools/aws-emulator && mkdir -p .tools/aws-emulator
  dpkg-deb -x "$tmp/emulator.deb" .tools/aws-emulator
  rm -rf "$tmp"
  "$EMULATOR_BIN" -v
}

start() {
  if command -v aws-emulator >/dev/null; then
    exec aws-emulator -p "$EMULATOR_PORT"
  fi
  case "$(uname -s)" in
    Linux)
      if ! "$EMULATOR_BIN" -v 2>/dev/null | grep -qx "Version: $EMULATOR_VERSION"; then install; fi
      exec "$EMULATOR_BIN" -p "$EMULATOR_PORT"
      ;;
    *)
      local arch package
      case "$(uname -m)" in arm64 | aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
      package="aws-emulator-${EMULATOR_VERSION}-1-${arch}.rpm"
      docker build -t aws-emulator --build-arg "PACKAGE=$package" -f scripts/emulator.Dockerfile scripts
      # The emulator writes this run's credentials and certificate under HOME, so
      # the container shares that folder with the tools out here.
      mkdir -p "$HOME/.aws/emulator"
      exec docker run --rm --memory=2g --memory-swap=2g \
        -p "127.0.0.1:$EMULATOR_PORT:$EMULATOR_PORT" \
        -e HOME="$HOME" -v "$HOME/.aws/emulator:$HOME/.aws/emulator" \
        aws-emulator -p "$EMULATOR_PORT"
      ;;
  esac
}

up() {
  if [ ! -f "$AWS_CA_BUNDLE" ]; then
    echo "No emulator found on port $EMULATOR_PORT. Start one in another terminal first: scripts/emulator.sh start"
    exit 1
  fi
  if [ ! -d data/raw/events ]; then
    uv run python scripts/generate_fake_events.py
  fi
  # A fresh emulator knows nothing about the last one's resources.
  rm -f infra/emulator.tfstate infra/emulator.tfstate.backup
  terraform -chdir=infra init -input=false
  terraform -chdir=infra apply -auto-approve -input=false -state=emulator.tfstate \
    -var "bucket_name=$BUCKET" -var "region=$AWS_REGION"
  aws s3 sync data/raw/events "s3://$BUCKET/raw/events/" --delete --only-show-errors
  (
    cd beer_sales
    export DBT_PROFILES_DIR="$PWD" DBT_TARGET=emulator
    export EVENTS_LOCATION="s3://$BUCKET/raw/events/*.parquet"
    export SUMMARY_LOCATION="s3://$BUCKET/summary/daily_event_summary.parquet"
    uv run dbt build
  )
  echo
  echo "The emulator has the stack, the events and the summary. Next: scripts/three_environments.sh"
}

case "${1:-}" in
  start) start ;;
  up) up ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
