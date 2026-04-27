import duckdb
import os
import pandas as pd
import re
from datetime import datetime, timedelta

DB_PATH = "dev.duckdb"
OUTPUT_DIR = "csv_output"
os.makedirs(OUTPUT_DIR, exist_ok=True)

def clean_timestamp_series(series):
    def fix_one(val):
        if pd.isna(val):
            return val
        
        str_val = str(val)
        pattern = r'(\d+)/(\d+)/(\d+)\s+(\d+):(\d+)\.(\d+)'
        match = re.match(pattern, str_val)
        
        if match:
            month, day, year, hour, minute, second = match.groups()
            hour = int(hour)

            if hour >= 24:
                days_to_add = hour // 24
                new_hour = hour % 24
                dt = datetime(int(year), int(month), int(day))
                dt += timedelta(days=days_to_add)
                return f"{dt.month}/{dt.day}/{dt.year} {new_hour:02d}:{minute}.{second}"
        
        return str_val

    return series.apply(fix_one)

con = duckdb.connect(DB_PATH)

tables = con.execute("""
    SELECT table_name
    FROM information_schema.tables
    WHERE LOWER(table_name) LIKE 'mart_%'
""").fetchall()

print(f"Found {len(tables)} mart tables")

for (table_name,) in tables:
    output_file = os.path.join(OUTPUT_DIR, f"{table_name}.csv")
    print(f"Exporting {table_name} -> {output_file}")

    # 🔥 get column names
    columns = con.execute(f"""
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = '{table_name}'
    """).fetchall()

    data = {}

    for (col_name,) in columns:
        try:
            # ✅ extract column as STRING ONLY
            col_df = con.execute(f'''
                SELECT "{col_name}"::VARCHAR AS val
                FROM "{table_name}"
            ''').fetchdf()

            data[col_name] = col_df["val"]

        except Exception as e:
            print(f"  ⚠️ Skipping column {col_name}: {e}")
            data[col_name] = []

    # build dataframe safely
    df = pd.DataFrame(data)

    # clean timestamp-like columns
    for col in df.columns:
        sample_values = df[col].dropna().astype(str).head(5)

        if any(re.search(r'\d+/\d+/\d+\s+\d+:', val) for val in sample_values):
            df[col] = clean_timestamp_series(df[col])

    # clean nan
    df = df.replace('nan', '')

    df.to_csv(output_file, index=False)

    print(f"  ✅ Exported {len(df)} rows")

con.close()

print("✅ Export complete!")