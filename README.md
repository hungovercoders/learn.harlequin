# learn.harlequin

The code behind a three-part [hungovercoders](https://hungovercoders.com) series on local-first data engineering. A fake craft beer shop's events go through one small pipeline, which starts as two SQL files on a laptop and ends as a scheduled job on AWS without the SQL changing.

## The series

| Part | Post | What it adds |
| --- | --- | --- |
| 1 | [Delightful Local Data Engineering with DuckDB and Harlequin](https://hungovercoders.com/blog/2026-09-13-delightful-local-data-engineering-with-duckdb-and-harlequin) | Fake events as parquet, DuckDB, Harlequin and hsql |
| 2 | [Rigorous Local Data Engineering with DuckDB and dbt](https://hungovercoders.com/blog/2026-10-31-rigorous-local-data-engineering-with-duckdb-and-dbt) | A dbt project with a staging view, a mart, a seed and tests |
| 3 | [Deployed Data Engineering with DuckDB, dbt and AWS](https://hungovercoders.com/blog/2026-11-21-deployed-data-engineering-with-duckdb-dbt-and-aws) | A container, AWS Emulator and a scheduled Fargate job |

A longer, do-it-by-hand version of each part is in [`docs/`](./docs).

## What is in here

```txt
beer_sales/     the dbt project: sources, staging, marts, an export, a seed and tests
infra/          Terraform for the AWS deployment, also applied to AWS Emulator
scripts/        the event generator, and sh files that wrap the emulator and AWS steps
sql/pipeline/   the two plain SQL files from part 1
docs/           the three tutorials and their images
Dockerfile      the job: an image whose command is `uv run dbt build`
```

## You will need

- [uv](https://docs.astral.sh/uv/) for everything
- Docker, Terraform and the AWS CLI from part 3 onwards
- An AWS account with its default VPC, for the real AWS steps only

Terraform is pinned in `mise.toml` for anyone using [mise](https://mise.jdx.dev/).

## Run it on a laptop

```bash
uv sync
uv run python scripts/generate_fake_events.py

cd beer_sales
export DBT_PROFILES_DIR="$(pwd)"
uv run dbt build
```

That builds `beer_sales/beers.duckdb` and writes `data/daily_event_summary.parquet`. Open the database with `uv run harlequin beers.duckdb`.

The same build as a container, from the repo root:

```bash
docker build -t beer-sales .
docker run --rm -v "$(pwd)/data:/app/data" beer-sales
```

## Run it against AWS Emulator

[AWS Emulator](https://github.com/aws/aws-emulator) answers the AWS APIs on a local port. In one terminal:

```bash
scripts/emulator.sh start
```

In another:

```bash
scripts/emulator.sh up
```

`start` uses an `aws-emulator` already on your PATH. Without one it downloads a pinned version and checks AWS's signature on a Debian-style Linux or WSL, and runs the emulator in Docker on macOS or Windows. `up` applies `infra/` to the emulator, uploads the events and runs `dbt build` with the `emulator` target.

The emulator takes the Terraform and stands in for S3. It does not run the Fargate task.

## Run it on AWS

Log in to AWS first. This creates real resources, which cost a little while they exist.

```bash
export ALERT_EMAIL=me@example.com   # your own address, for failure alerts
scripts/aws.sh deploy               # Terraform, the image and the events
scripts/aws.sh run                  # run the job now and print its log
scripts/aws.sh destroy              # empty the bucket and remove everything
```

| Command | What it does |
| --- | --- |
| `deploy` | Applies `infra/`, builds and pushes the image, uploads the events |
| `run` | Starts the Fargate task, waits for it, prints the dbt log and the summary file |
| `break` | Ships an image with a failing test and runs it, to prove the failure alert |
| `fix` | Ships the good image again |
| `resources` | Lists the environment's resource group |
| `query` | Asks the summary in S3 which beers are paying the bills |
| `destroy` | Empties the bucket and removes everything |

The job is scheduled for 06:00 UTC every day until it is destroyed. The script's reports swap the AWS account id and the alert email for stand-ins, so they are safe to share.

## The same answer in three places

With the laptop build done, the emulator up and the AWS stack deployed:

```bash
scripts/three_environments.sh
```

It runs one query against the summary file in each environment and says whether the answers match.

## Licence

[MIT](./LICENSE)
