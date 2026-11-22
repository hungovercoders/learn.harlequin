#!/usr/bin/env bash
# Deploy, run, break and remove the beer sales job on a real AWS account.
# Log in to AWS first, then from anywhere in the repo:
#
#   scripts/aws.sh bootstrap once per account: shared Terraform state and a role for GitHub Actions
#   scripts/aws.sh deploy    infrastructure, image and events
#   scripts/aws.sh run       run the job now, wait for it, show its log and the summary file
#   scripts/aws.sh break     ship an image with a failing test and run it, to prove the alert
#   scripts/aws.sh fix       ship the good image again
#   scripts/aws.sh resources list everything in the environment's resource group
#   scripts/aws.sh query     ask the summary in S3 which beers are paying the bills
#   scripts/aws.sh destroy   empty the bucket and remove everything
#   scripts/aws.sh summary-location   print where the summary file is, for other scripts
#
# Optional settings, as environment variables:
#   AWS_REGION    where to deploy (default eu-west-2)
#   ALERT_EMAIL   who is told when the job fails; give it on every deploy
#   BUCKET_NAME   a bucket name of your own (default beer-sales-<account id>-<region>)
#   AUTO_APPROVE  set to true and Terraform does not stop to ask; for GitHub Actions
#   GITHUB_REPO   the owner/name allowed to deploy (default: this clone's origin); bootstrap only
#
# Terraform's state is a file in infra/ until bootstrap has been run. After that it
# lives in S3, where a laptop and GitHub Actions both find it.
#
# The report from run and break has the account id and alert email swapped for
# stand-ins, so it is safe to screenshot. Terraform and docker output is not.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
  echo "AWS_ENDPOINT_URL is set ($AWS_ENDPOINT_URL), so this shell is pointed at an emulator."
  echo "Open a fresh terminal for the real account."
  exit 1
fi

REGION="${AWS_REGION:-eu-west-2}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
VARS=(-var "region=$REGION" -var "alert_email=${ALERT_EMAIL:-}")
if [ -n "${BUCKET_NAME:-}" ]; then VARS+=(-var "bucket_name=$BUCKET_NAME"); fi

# Left unquoted where it is used, so that empty means no argument at all.
APPROVE=""
if [ "${AUTO_APPROVE:-}" = "true" ]; then APPROVE="-auto-approve"; fi

tf() { terraform -chdir=infra "$@"; }
out() { tf output -raw "$1"; }

account() { aws sts get-caller-identity --query Account --output text; }

state_bucket() { echo "beer-sales-tfstate-$(account)-$REGION"; }

# Point Terraform at the state: the bucket bootstrap made if this account has one,
# a file in infra/ if not. The override file is how the emulator, which never
# shares state, gets to use the same infra/ with no backend in it.
init() {
  local bucket how="${1:--reconfigure}"
  bucket="$(state_bucket)"
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    cat > infra/backend_override.tf <<EOF
terraform {
  backend "s3" {
    bucket       = "$bucket"
    key          = "beer-sales/terraform.tfstate"
    region       = "$REGION"
    use_lockfile = true
  }
}
EOF
  else
    rm -f infra/backend_override.tf
  fi
  # shellcheck disable=SC2086 # how is one flag or two
  tf init -input=false $how >/dev/null
}

# What this script prints ends up in screenshots, so the account id and the
# alert email are swapped for stand-ins on the way out.
scrub() {
  local id
  id="$(account)"
  if [ -n "${ALERT_EMAIL:-}" ]; then
    sed -e "s/$id/123456789012/g" -e "s/$ALERT_EMAIL/me@example.com/g"
  else
    sed -e "s/$id/123456789012/g"
  fi
}

whoami_aws() {
  local id
  id="$(account)"
  # Enough to tell accounts apart, not enough to give one away.
  echo "AWS account ending ${id: -4}, region $REGION"
}

push_image() {
  local repo
  repo="$(out ecr_repository_url)"
  aws ecr get-login-password | docker login --username AWS --password-stdin "${repo%%/*}"
  # The task runs on x86, whatever this machine is.
  docker build --platform linux/amd64 -t "$repo:latest" .
  docker push "$repo:latest"
}

github_repo() {
  local url
  url="$(git remote get-url origin)"
  url="${url%.git}"
  echo "${GITHUB_REPO:-$(echo "$url" | sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#')}"
}

bootstrap() {
  local repo provider=true
  repo="$(github_repo)"
  whoami_aws
  echo "GitHub repository allowed to deploy: $repo"
  # An account has one GitHub identity provider at most, and another project may have made it.
  if aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text \
    | grep -q 'oidc-provider/token.actions.githubusercontent.com'; then
    provider=false
  fi
  terraform -chdir=infra/bootstrap init -input=false >/dev/null
  terraform -chdir=infra/bootstrap apply $APPROVE -var "region=$REGION" \
    -var "github_repository=$repo" -var "create_oidc_provider=$provider"
  # Anything already deployed from this laptop moves into the shared state with it.
  init "-migrate-state -force-copy"
  rm -f infra/terraform.tfstate infra/terraform.tfstate.backup
  echo
  echo "Bootstrapped. In the GitHub repository's settings, under secrets and variables for Actions, add:"
  echo "  secret   AWS_DEPLOY_ROLE_ARN   $(terraform -chdir=infra/bootstrap output -raw deploy_role_arn)"
  echo "  secret   ALERT_EMAIL           the address told when the job fails"
  echo "  variable AWS_REGION            $REGION"
  echo "  variable DEPLOY_TO_AWS         true"
  echo "The role's ARN has your account id in it, so do not screenshot the first of those."
}

deploy() {
  whoami_aws
  tf apply $APPROVE "${VARS[@]}"
  push_image
  # The same events as the laptop and the emulator, so all three can be compared.
  if [ ! -d data/raw/events ]; then
    uv run python scripts/generate_fake_events.py
  fi
  aws s3 sync data/raw/events "s3://$(out bucket)/raw/events/" --delete --only-show-errors
  echo
  echo "Deployed. Bucket: $(out bucket)" | scrub
  if [ -n "${ALERT_EMAIL:-}" ]; then
    echo "Confirm the subscription email AWS sent you, or no alerts will arrive."
  else
    echo "No ALERT_EMAIL was given, so nobody is told when the job fails."
  fi
  echo "Next: scripts/aws.sh run"
}

run() {
  local cluster group bucket task id status code
  cluster="$(out cluster)"
  group="$(out log_group)"
  bucket="$(out bucket)"
  task="$(eval "$(out run_task_command) --query 'tasks[0].taskArn' --output text")"
  id="${task##*/}"
  echo "Started task $id - waiting for it to finish, usually a minute or two"
  aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task"

  status="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" \
    --query 'tasks[0].[stopCode,stoppedReason]' --output text)"
  code="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" \
    --query 'tasks[0].containers[0].exitCode' --output text)"

  {
    echo
    echo "--- dbt log ($group) ---"
    aws logs get-log-events --log-group-name "$group" --log-stream-name "dbt/dbt/$id" \
      --start-from-head --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' \
      || echo "(no log stream - the task never started)"
    echo
    echo "--- summary in s3://$bucket/summary/ ---"
    aws s3 ls "s3://$bucket/summary/" || echo "(nothing there yet)"
    echo
    echo "Task stopped: $status"
  } | scrub
  if [ "$code" = "0" ]; then
    echo "Exit code 0 - the job passed"
  else
    echo "Exit code $code - the job failed"
    return 1
  fi
}

break_it() {
  local seed=beer_sales/seeds/beers.csv keep
  keep="$(mktemp)"
  cp "$seed" "$keep"
  # Whatever happens next, the beer list goes back as it was.
  # shellcheck disable=SC2064 # expand the paths now: they are local to this function
  trap "cp '$keep' '$seed'; rm -f '$keep'" EXIT
  grep -v '^Dutty$' "$keep" > "$seed"
  echo "Dutty is off the beer list - shipping an image that fails its test"
  push_image
  cp "$keep" "$seed"
  run || true
  echo
  echo "That failure should reach the alert email within a few minutes."
  echo "Next: scripts/aws.sh fix"
}

resources() {
  local group
  group="$(out resource_group)"
  echo "--- resource group $group ---"
  aws resource-groups list-group-resources --group-name "$group" \
    --query 'Resources[].Identifier.[ResourceType,ResourceArn]' --output text | sort \
    | awk -F'\t' '{ printf "%-27s %s\n", $1, $2 }' | scrub
}

query() {
  local location sql
  location="$(out summary_location)"
  sql="select beer, sum(event_count) as purchases, round(sum(revenue), 2) as revenue
from read_parquet('$location')
where event_type = 'purchase'
group by beer
order by revenue desc"
  {
    echo "--- beer revenue, read straight from $location ---"
    echo "$sql"
    echo
  } | scrub
  (
    # DuckDB finds credentials the way the AWS CLI does. Handing it this
    # shell's own makes that true for an SSO login as well.
    eval "$(aws configure export-credentials --format env 2>/dev/null)" || true
    uv run hsql -c "install httpfs; load httpfs; install aws; load aws;
      create or replace secret aws_s3 (type s3, provider credential_chain, region '$REGION'${S3_SECRET_OPTIONS:-});
      $sql"
  ) | sed '1,4{/^ Success$/d;/^-*$/d;/^ true$/d;/^(1 row)$/d;}' | scrub
}

destroy() {
  whoami_aws
  aws s3 rm "s3://$(out bucket)" --recursive --only-show-errors
  tf destroy $APPROVE "${VARS[@]}"
}

case "${1:-}" in
  bootstrap) bootstrap ;;
  deploy) init; deploy ;;
  run) init; run ;;
  break) init; break_it ;;
  fix) init; push_image; echo "The good image is back. Next: scripts/aws.sh run" ;;
  resources) init; resources ;;
  summary-location) init; out summary_location ;;
  query) init; query ;;
  destroy) init; destroy ;;
  *) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
