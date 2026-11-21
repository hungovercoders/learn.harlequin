#!/usr/bin/env bash
# Ask the same question of the same pipeline in all three environments, and say whether
# the answers match: the laptop's file, AWS Emulator's S3 and real S3.
#
#   scripts/three_environments.sh
#
# Run it from a shell logged in to the real account. An environment that is not up is
# skipped. Account ids are swapped for stand-ins, so the output is safe to screenshot.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
  echo "AWS_ENDPOINT_URL is set, so this shell is pointed at an emulator."
  echo "Open a fresh terminal logged in to the real account; the emulator is reached from here anyway."
  exit 1
fi

REGION="${AWS_REGION:-eu-west-2}"
export AWS_PAGER=""
answers="$(mktemp -d)"
trap 'rm -rf "$answers"' EXIT

sql() {
  echo "select beer, sum(event_count) as purchases, round(sum(revenue), 2) as revenue
from read_parquet('$1')
where event_type = 'purchase'
group by beer
order by revenue desc"
}

# hsql prints the result of making the secret as well; that table goes.
table_only() { sed '1,4{/^ Success$/d;/^-*$/d;/^ true$/d;/^(1 row)$/d;}'; }

ask() { # name, setup SQL, location
  uv run hsql -c "$2 $(sql "$3")" 2>/dev/null | table_only | tee "$answers/$1"
}

echo "Which beers are paying the bills? One query, three places."

echo
echo "=== 1. My laptop ==="
local_file=data/daily_event_summary.parquet
if [ -f "$local_file" ]; then
  echo "    $local_file"
  ask laptop "" "$local_file"
else
  echo "    skipped: no $local_file - run dbt build in beer_sales first"
fi

echo
echo "=== 2. AWS Emulator ==="
(
  # shellcheck source=scripts/emulator_env.sh
  source scripts/emulator_env.sh
  location="s3://beer-sales-local/summary/daily_event_summary.parquet"
  if [ -f "$AWS_CA_BUNDLE" ] && aws s3 ls "$location" >/dev/null 2>&1; then
    echo "    $location on 127.0.0.1:$EMULATOR_PORT"
    ask emulator "install httpfs; load httpfs; install aws; load aws;
      set ca_cert_file='$AWS_CA_BUNDLE';
      create or replace secret emulator (type s3, provider credential_chain, region '$AWS_REGION',
        endpoint '127.0.0.1:$EMULATOR_PORT', url_style 'path', use_ssl true);" "$location"
  else
    echo "    skipped: no emulator with a summary - run scripts/emulator.sh up"
  fi
)

echo
echo "=== 3. AWS ($REGION) ==="
(
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
  if location="$(terraform -chdir=infra output -raw summary_location 2>/dev/null)" \
    && account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    && aws s3 ls "$location" >/dev/null 2>&1; then
    echo "    ${location//$account/123456789012}"
    # DuckDB finds credentials the way the AWS CLI does. Handing it this
    # shell's own makes that true for an SSO login as well.
    eval "$(aws configure export-credentials --format env 2>/dev/null)" || true
    ask aws "install httpfs; load httpfs; install aws; load aws;
      create or replace secret aws_s3 (type s3, provider credential_chain, region '$REGION');" "$location"
  else
    echo "    skipped: nothing deployed in this account - run scripts/aws.sh deploy and run"
  fi
)

echo
count="$(find "$answers" -type f | wc -l | tr -d ' ')"
different="$(cat "$answers"/* 2>/dev/null | sort | uniq -c | awk -v n="$count" '$1 != n' | wc -l | tr -d ' ')"
if [ "$count" -lt 2 ]; then
  echo "Only $count environment answered, so there is nothing to compare."
elif [ "$different" = "0" ]; then
  echo "Same answer in all $count environments."
else
  echo "The environments disagree - they are not looking at the same events."
  exit 1
fi
