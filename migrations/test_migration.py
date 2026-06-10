#!/usr/bin/env python3
"""
Test script for CSV parsing and type conversion.

Run without database connection to validate CSV reading and data conversion.
"""

import sys
from pathlib import Path

# Import from load_csv
from load_csv import SCHEMAS, read_csv


def test_mindshare_user_csv():
    """Test reading and converting mindshare_user CSV."""
    csv_file = Path("test_mindshare_user.csv")

    if not csv_file.exists():
        print(f"❌ CSV file not found: {csv_file}")
        return False

    print(f"✓ Found CSV file: {csv_file}")

    schema = SCHEMAS["mindshare_user"]
    rows = list(read_csv(csv_file, schema))

    if not rows:
        print("❌ No rows read from CSV")
        return False

    print(f"✓ Read {len(rows)} rows from CSV")

    # Validate first row
    first_row = rows[0]
    print(f"\n✓ First row (converted types):")
    for col in schema["columns"]:
        value = first_row[col]
        value_type = type(value).__name__
        print(f"  {col}: {value_type} = {repr(value)[:60]}")

    # Check for nulls
    null_count = sum(1 for row in rows for col in schema["columns"] if row[col] is None)
    print(f"\n✓ Total NULL values: {null_count}")

    # Validate types
    errors = []
    for row_num, row in enumerate(rows, 1):
        # x_id should be str
        if not isinstance(row["x_id"], str):
            errors.append(f"Row {row_num}: x_id is {type(row['x_id'])}, expected str")

        # score should be float or None
        if row["score"] is not None and not isinstance(row["score"], float):
            errors.append(f"Row {row_num}: score is {type(row['score'])}, expected float")

        # followers_count should be int or None
        if row["followers_count"] is not None and not isinstance(row["followers_count"], int):
            errors.append(f"Row {row_num}: followers_count is {type(row['followers_count'])}, expected int")

        # verified should be bool
        if not isinstance(row["verified"], bool):
            errors.append(f"Row {row_num}: verified is {type(row['verified'])}, expected bool")

        # adjustment_config should be dict
        if not isinstance(row["adjustment_config"], dict):
            errors.append(f"Row {row_num}: adjustment_config is {type(row['adjustment_config'])}, expected dict")

    if errors:
        print("\n❌ Type validation errors:")
        for error in errors[:10]:  # Show first 10
            print(f"  {error}")
        if len(errors) > 10:
            print(f"  ... and {len(errors) - 10} more errors")
        return False

    print("\n✓ All type validations passed!")
    print("\nCSV migration test: SUCCESS ✓")
    return True


if __name__ == "__main__":
    success = test_mindshare_user_csv()
    sys.exit(0 if success else 1)
