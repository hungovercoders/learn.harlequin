from pathlib import Path
from datetime import datetime, timedelta, timezone
import random
import uuid

import pandas as pd
from faker import Faker

fake = Faker()
random.seed(42)
Faker.seed(42)

OUT_DIR = Path("data/raw/events")
OUT_DIR.mkdir(parents=True, exist_ok=True)

NUM_EVENTS = 50_000
NUM_CUSTOMERS = 2_000

customer_ids = [f"cust_{i:05d}" for i in range(NUM_CUSTOMERS)]
event_types = [
    "page_view",
    "search",
    "product_view",
    "add_to_cart",
    "checkout_started",
    "purchase",
]

devices = ["web", "ios", "android"]

end = datetime.now(timezone.utc)
start = end - timedelta(days=30)

rows = []

for _ in range(NUM_EVENTS):
    event_time = start + timedelta(
        seconds=random.randint(0, int((end - start).total_seconds()))
    )

    customer_id = random.choice(customer_ids)

    rows.append(
        {
            "event_id": str(uuid.uuid4()),
            "event_timestamp": event_time,
            "customer_id": customer_id,
            "session_id": str(uuid.uuid4()),
            "event_type": random.choices(
                event_types, weights=[40, 10, 22, 12, 8, 8], k=1
            )[0],
            "device": random.choice(devices),
            "country": fake.country_code(),
            "revenue": (
                round(random.uniform(5, 250), 2) if random.random() < 0.08 else 0.0
            ),
        }
    )

df = pd.DataFrame(rows)

# Partition into one Parquet file per day.
df["event_date"] = pd.to_datetime(df["event_timestamp"]).dt.date

for event_date, day_df in df.groupby("event_date"):
    path = OUT_DIR / f"events_{event_date}.parquet"
    day_df.drop(columns=["event_date"]).to_parquet(path, index=False)

print(f"Generated {len(df):,} events in {OUT_DIR}")
