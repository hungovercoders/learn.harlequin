#!/usr/bin/env bash
# Stand the beer sales job's infrastructure up on AWS Emulator and run dbt against it.
# Start the emulator in another terminal first (aws-emulator -p 9297), then:
#
#   scripts/emulator.sh up     apply infra/ to the emulator, upload the events, run dbt build
#
# The emulator forgets everything when it stops, so run this again after a restart.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/emulator_env.sh
source scripts/emulator_env.sh
BUCKET=beer-sales-local

up() {
  if [ ! -f "$AWS_CA_BUNDLE" ]; then
    echo "No emulator found on port $EMULATOR_PORT. Start one first: aws-emulator -p $EMULATOR_PORT"
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
  echo "The emulator has the stack, the events and the summary. Next: scripts/three_rungs.sh"
}

case "${1:-}" in
  up) up ;;
  *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
