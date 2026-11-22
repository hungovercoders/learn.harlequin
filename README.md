# learn.harlequin

The code behind a [hungovercoders](https://hungovercoders.com) series on local-first data engineering. A fake craft beer shop's events go through one small pipeline, which starts as two SQL files on a laptop and ends as a scheduled job on AWS without the SQL changing.

## The series

| Part | Post | What it adds |
| --- | --- | --- |
| 1 | [Delightful Local Data Engineering with DuckDB and Harlequin](https://hungovercoders.com/blog/2026-09-13-delightful-local-data-engineering-with-duckdb-and-harlequin) | Fake events as parquet, DuckDB, Harlequin and hsql |
| 2 | [Rigorous Local Data Engineering with DuckDB and dbt](https://hungovercoders.com/blog/2026-10-31-rigorous-local-data-engineering-with-duckdb-and-dbt) | A dbt project with a staging view, a mart, a seed and tests |
| 3 | [Deployed Data Engineering with DuckDB, dbt and AWS](https://hungovercoders.com/blog/2026-11-21-deployed-data-engineering-with-duckdb-dbt-and-aws) | A container, AWS Emulator and a scheduled Fargate job |

Part 4, on the way, adds a Taskfile, a pull request check that runs against AWS Emulator and a GitHub Action that deploys.

A longer, do-it-by-hand version of each part is in [`docs/`](./docs).

## What is in here

```txt
beer_sales/     the dbt project: sources, staging, marts, an export, a seed and tests
infra/          Terraform for the AWS deployment, also applied to AWS Emulator
infra/bootstrap one-off Terraform: shared state and a role GitHub Actions can take on
scripts/        the event generator, and sh files that wrap the emulator and AWS steps
Taskfile.yml    one name for every step, used by a laptop and by GitHub Actions
.github/        the pull request check and the deploy
sql/pipeline/   the two plain SQL files from part 1
docs/           the three tutorials and their images
Dockerfile      the job: an image whose command is `uv run dbt build`
```

## You will need

- [uv](https://docs.astral.sh/uv/) for everything
- Docker, Terraform and the AWS CLI from part 3 onwards
- [Task](https://taskfile.dev/) to run the steps by name; `task` on its own lists them
- An AWS account with its default VPC, for the real AWS steps only

Terraform, Task and uv are pinned in `mise.toml` for anyone using [mise](https://mise.jdx.dev/). Every `task` command below runs an sh file in `scripts/`, which works without Task too.

## Run it on a laptop

```bash
task setup
task build
```

That generates the events, builds `beer_sales/beers.duckdb` and writes `data/daily_event_summary.parquet`. Open the database with `uv run harlequin beer_sales/beers.duckdb`.

The same build as a container, from the repo root:

```bash
docker build -t beer-sales .
docker run --rm -v "$(pwd)/data:/app/data" beer-sales
```

## Run it against AWS Emulator

[AWS Emulator](https://github.com/aws/aws-emulator) answers the AWS APIs on a local port. In one terminal:

```bash
task emulator:start
```

In another:

```bash
task emulator:up
task emulator:container
task emulator:check
```

`start` uses an `aws-emulator` already on your PATH. Without one it downloads a pinned version and checks AWS's signature on a Debian-style Linux or WSL, and runs the emulator in Docker on macOS or Windows. `up` applies `infra/` to the emulator, uploads the events and runs `dbt build` with the `emulator` target. `container` runs the job's image against the emulator's S3, and `check` reads the summary back out of it.

The emulator takes the Terraform and stands in for S3. It does not run the Fargate task.

## Run it on AWS

Log in to AWS first. This creates real resources, which cost a little while they exist.

```bash
export ALERT_EMAIL=me@example.com   # your own address, for failure alerts
task aws:deploy                     # Terraform, the image and the events
task aws:run                        # run the job now and print its log
task aws:destroy                    # empty the bucket and remove everything
```

| Command | What it does |
| --- | --- |
| `aws:bootstrap` | Once per account: shared Terraform state and a role for GitHub Actions |
| `aws:deploy` | Applies `infra/`, builds and pushes the image, uploads the events |
| `aws:run` | Starts the Fargate task, waits for it, prints the dbt log and the summary file |
| `aws:break` | Ships an image with a failing test and runs it, to prove the failure alert |
| `aws:fix` | Ships the good image again |
| `aws:resources` | Lists the environment's resource group |
| `aws:query` | Asks the summary in S3 which beers are paying the bills |
| `aws:destroy` | Empties the bucket and removes everything |

The job is scheduled for 06:00 UTC every day until it is destroyed. The script's reports swap the AWS account id and the alert email for stand-ins, so they are safe to share.

## The same answer in three places

With the laptop build done, the emulator up and the AWS stack deployed:

```bash
task compare
```

It runs one query against the summary file in each environment and says whether the answers match.

## Checked on every pull request

`task ci` is the whole check: it lints the Terraform, starts AWS Emulator, applies `infra/` to it, runs dbt against its S3, runs the job's image against it and reads the summary back. [`.github/workflows/ci.yml`](./.github/workflows/ci.yml) runs that one command on every pull request. It needs no AWS account and no secrets.

## Deployed from main

[`.github/workflows/deploy.yml`](./.github/workflows/deploy.yml) runs `task aws:deploy` and then `task aws:run` when main changes. It stores no AWS key: GitHub vouches for the workflow and AWS hands it an hour's credentials. To switch it on, log in to AWS on a laptop and run:

```bash
task aws:bootstrap
```

That creates a bucket for Terraform's state and a role only this repository's main branch can take on, moves any state already on the laptop into the bucket, and prints the two secrets and two variables to add in the repository's settings. The deploy does nothing until the variable `DEPLOY_TO_AWS` is `true`. The same workflow, started by hand with the `destroy` option, removes the stack.

To remove the bootstrap as well, after destroying the stack: `terraform -chdir=infra/bootstrap destroy`.

## Licence

[MIT](./LICENSE)
