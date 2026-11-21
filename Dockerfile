FROM python:3.12-slim

RUN pip install --no-cache-dir uv

WORKDIR /app

# Install dependencies first so this layer is cached until the lockfile changes.
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-install-project

COPY beer_sales ./beer_sales

WORKDIR /app/beer_sales
ENV DBT_PROFILES_DIR=/app/beer_sales

CMD ["uv", "run", "--frozen", "dbt", "build"]
