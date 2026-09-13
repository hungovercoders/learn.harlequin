from pathlib import Path
from datetime import datetime, timedelta, timezone
import random, uuid
import pandas as pd
from faker import Faker

fake = Faker()
random.seed(42)
Faker.seed(42)

out = Path("data/raw/events")
out.mkdir(parents=True, exist_ok=True)

types = [
    "page_view",
    "search",
    "product_view",
    "add_to_cart",
    "checkout_started",
    "purchase",
]
devices = ["web", "ios", "android"]
customers = [f"cust_{i:05d}" for i in range(2000)]
end = datetime.now(timezone.utc)
start = end - timedelta(days=30)
rows = []

for _ in range(50_000):
    event_type = random.choices(types, weights=[40, 10, 22, 12, 8, 8], k=1)[0]
    rows.append(
        {
            "event_id": str(uuid.uuid4()),
            "event_timestamp": start
            + timedelta(seconds=random.randint(0, int((end - start).total_seconds()))),
            "customer_id": random.choice(customers),
            "session_id": str(uuid.uuid4()),
            "event_type": event_type,
            "device": random.choice(devices),
            "country": fake.country_code(),
            "revenue": (
                round(random.uniform(5, 250), 2) if event_type == "purchase" else 0.0
            ),
        }
    )

df = pd.DataFrame(rows)
df["day"] = pd.to_datetime(df["event_timestamp"]).dt.date
for day, frame in df.groupby("day"):
    frame.drop(columns=["day"]).to_parquet(out / f"events_{day}.parquet", index=False)
