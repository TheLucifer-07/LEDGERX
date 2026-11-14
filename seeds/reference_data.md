# Fictional Reference Data

- **Purpose:** load currencies, fictional customer identities, system clearing accounts, wallets, and one balance-projection row per account.
- **Dependencies:** migrations `0001_platform_roles.sql` and `0002_core_schema.sql`.
- **Concepts:** explicit currency scales, constrained account kinds/normal sides, stable natural identifiers, and rerunnable inserts with unique conflict targets.
- **Important statements:** seed currencies first; customer rows are then available to account ownership subqueries. The final insert initializes missing projection rows without overwriting balances.
- **Why this approach:** fixtures use recognizable stable codes so SQL tests remain readable and repeatable. Names and references are fictional.
- **Alternatives:** generated identity IDs embedded in every test or a large random seed. Stable account codes avoid coupling tests to sequence values.
- **Failure cases:** changing an existing code's meaning in place could confuse prior test history; add a new test account code instead. This seed does not reset balances or delete ledger history.
- **Execute:** `scripts/seed.sh`, or indirectly through `scripts/setup.sh`.
- **Verify:** `SELECT account_code, currency_code, normal_side FROM ledger.accounts ORDER BY account_code;` as an authorized local reader.
- **Interview questions:** Why use a currency table? Why is account code unique? Why should seed setup avoid resetting mutable balances?
